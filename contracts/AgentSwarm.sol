// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract AgentSwarm {

    // ──────────────────────────────────────────────
    //  ERC-20: $SWARM Token (inline minimal ERC20)
    // ──────────────────────────────────────────────

    string public constant name     = "AgentSwarm Protocol";
    string public constant symbol   = "SWARM";
    uint8  public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        return _transfer(msg.sender, to, value);
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= value, "ERC20: allowance exceeded");
            allowance[from][msg.sender] = allowed - value;
        }
        return _transfer(from, to, value);
    }

    function _transfer(address from, address to, uint256 value) internal returns (bool) {
        require(from != address(0), "ERC20: transfer from zero");
        require(to   != address(0), "ERC20: transfer to zero");
        require(balanceOf[from] >= value, "ERC20: insufficient balance");
        balanceOf[from] -= value;
        balanceOf[to]   += value;
        emit Transfer(from, to, value);
        return true;
    }

    function _mint(address to, uint256 value) internal {
        totalSupply    += value;
        balanceOf[to]  += value;
        emit Transfer(address(0), to, value);
    }

    // ──────────────────────────────────────────────
    //  Protocol State
    // ──────────────────────────────────────────────

    address public owner;
    address public treasury;
    address public stakingPool;
    address public insuranceFund;

    uint256 public constant MIN_STAKE        = 1_000 * 1e18;
    uint256 public constant COOLDOWN_PERIOD  = 7 days;
    uint256 public constant AUTO_RELEASE     = 72 hours;

    uint256 public nextAgentId;
    uint256 public nextTaskId;

    // ──────────────────────────────────────────────
    //  Agent Registry
    // ──────────────────────────────────────────────

    struct Agent {
        string   name;
        address  operator;
        string   capabilities;
        uint256  feePerTask;
        uint256  stake;
        uint256  totalTasks;
        uint256  successCount;
        bool     active;
        uint256  deactivatedAt;
    }

    mapping(uint256 => Agent) public agents;

    event AgentRegistered(uint256 indexed agentId, address indexed operator, string name, uint256 feePerTask);
    event AgentDeactivated(uint256 indexed agentId);
    event AgentUnstaked(uint256 indexed agentId, uint256 amount);

    // ──────────────────────────────────────────────
    //  Task Escrow
    // ──────────────────────────────────────────────

    enum TaskStatus { Open, Completed, Confirmed, Disputed, Resolved }

    struct Task {
        uint256    agentId;
        address    requester;
        string     prompt;
        uint256    payment;
        TaskStatus status;
        uint256    createdAt;
        uint256    completedAt;
    }

    mapping(uint256 => Task) public tasks;

    event TaskCreated(uint256 indexed taskId, uint256 indexed agentId, address indexed requester, uint256 payment);
    event TaskCompleted(uint256 indexed taskId);
    event TaskConfirmed(uint256 indexed taskId);
    event TaskDisputed(uint256 indexed taskId);
    event TaskResolved(uint256 indexed taskId, bool agentFavored);
    event PaymentReleased(uint256 indexed taskId, uint256 agentShare, uint256 treasuryShare, uint256 stakingShare, uint256 insuranceShare);

    // ──────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────

    constructor(address _treasury, address _stakingPool, address _insuranceFund) {
        require(_treasury     != address(0), "zero treasury");
        require(_stakingPool  != address(0), "zero staking pool");
        require(_insuranceFund != address(0), "zero insurance fund");

        owner         = msg.sender;
        treasury      = _treasury;
        stakingPool   = _stakingPool;
        insuranceFund = _insuranceFund;

        _mint(msg.sender, 1_000_000_000 * 1e18);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    // ──────────────────────────────────────────────
    //  Agent Registry Functions
    // ──────────────────────────────────────────────

    function registerAgent(
        string calldata _name,
        string calldata _capabilities,
        uint256 _feePerTask,
        uint256 _stakeAmount
    ) external returns (uint256 agentId) {
        require(_feePerTask > 0, "fee must be > 0");
        require(_stakeAmount >= MIN_STAKE, "stake below minimum");
        require(balanceOf[msg.sender] >= _stakeAmount, "insufficient SWARM");

        _transfer(msg.sender, address(this), _stakeAmount);

        agentId = nextAgentId++;
        agents[agentId] = Agent({
            name:          _name,
            operator:      msg.sender,
            capabilities:  _capabilities,
            feePerTask:    _feePerTask,
            stake:         _stakeAmount,
            totalTasks:    0,
            successCount:  0,
            active:        true,
            deactivatedAt: 0
        });

        emit AgentRegistered(agentId, msg.sender, _name, _feePerTask);
    }

    function deactivateAgent(uint256 agentId) external {
        Agent storage a = agents[agentId];
        require(a.operator == msg.sender, "not agent operator");
        require(a.active, "already inactive");

        a.active = false;
        a.deactivatedAt = block.timestamp;

        emit AgentDeactivated(agentId);
    }

    function withdrawStake(uint256 agentId) external {
        Agent storage a = agents[agentId];
        require(a.operator == msg.sender, "not agent operator");
        require(!a.active, "deactivate first");
        require(block.timestamp >= a.deactivatedAt + COOLDOWN_PERIOD, "cooldown active");
        require(a.stake > 0, "no stake");

        uint256 amount = a.stake;
        a.stake = 0;
        _transfer(address(this), msg.sender, amount);

        emit AgentUnstaked(agentId, amount);
    }

    // ──────────────────────────────────────────────
    //  Task Escrow Functions
    // ──────────────────────────────────────────────

    function createTask(uint256 agentId, string calldata _prompt) external returns (uint256 taskId) {
        Agent storage a = agents[agentId];
        require(a.active, "agent inactive");
        require(balanceOf[msg.sender] >= a.feePerTask, "insufficient SWARM for fee");

        _transfer(msg.sender, address(this), a.feePerTask);

        taskId = nextTaskId++;
        tasks[taskId] = Task({
            agentId:     agentId,
            requester:   msg.sender,
            prompt:      _prompt,
            payment:     a.feePerTask,
            status:      TaskStatus.Open,
            createdAt:   block.timestamp,
            completedAt: 0
        });

        a.totalTasks++;

        emit TaskCreated(taskId, agentId, msg.sender, a.feePerTask);
    }

    function completeTask(uint256 taskId) external {
        Task storage t = tasks[taskId];
        require(t.status == TaskStatus.Open, "task not open");

        Agent storage a = agents[t.agentId];
        require(a.operator == msg.sender, "not assigned agent");

        t.status = TaskStatus.Completed;
        t.completedAt = block.timestamp;

        emit TaskCompleted(taskId);
    }

    function confirmTask(uint256 taskId) external {
        Task storage t = tasks[taskId];
        require(t.requester == msg.sender, "not requester");
        require(t.status == TaskStatus.Completed, "not completed");

        t.status = TaskStatus.Confirmed;
        agents[t.agentId].successCount++;

        _distributePayment(taskId);

        emit TaskConfirmed(taskId);
    }

    function disputeTask(uint256 taskId) external {
        Task storage t = tasks[taskId];
        require(t.requester == msg.sender, "not requester");
        require(
            t.status == TaskStatus.Open || t.status == TaskStatus.Completed,
            "cannot dispute"
        );

        t.status = TaskStatus.Disputed;

        emit TaskDisputed(taskId);
    }

    function resolveDispute(uint256 taskId, bool agentFavored) external onlyOwner {
        Task storage t = tasks[taskId];
        require(t.status == TaskStatus.Disputed, "not disputed");

        t.status = TaskStatus.Resolved;

        if (agentFavored) {
            agents[t.agentId].successCount++;
            _distributePayment(taskId);
        } else {
            _transfer(address(this), t.requester, t.payment);
        }

        emit TaskResolved(taskId, agentFavored);
    }

    function autoRelease(uint256 taskId) external {
        Task storage t = tasks[taskId];
        require(t.status == TaskStatus.Completed, "not completed");
        require(block.timestamp >= t.completedAt + AUTO_RELEASE, "cooldown active");

        t.status = TaskStatus.Confirmed;
        agents[t.agentId].successCount++;

        _distributePayment(taskId);

        emit TaskConfirmed(taskId);
    }

    // ──────────────────────────────────────────────
    //  Revenue Distribution (70/15/10/5)
    // ──────────────────────────────────────────────

    function _distributePayment(uint256 taskId) internal {
        uint256 total = tasks[taskId].payment;
        uint256 agentShare     = (total * 70) / 100;
        uint256 treasuryShare  = (total * 15) / 100;
        uint256 stakingShare   = (total * 10) / 100;
        uint256 insuranceShare = total - agentShare - treasuryShare - stakingShare;

        address operator = agents[tasks[taskId].agentId].operator;

        _transfer(address(this), operator,      agentShare);
        _transfer(address(this), treasury,      treasuryShare);
        _transfer(address(this), stakingPool,   stakingShare);
        _transfer(address(this), insuranceFund, insuranceShare);

        emit PaymentReleased(taskId, agentShare, treasuryShare, stakingShare, insuranceShare);
    }

    // ──────────────────────────────────────────────
    //  View Helpers
    // ──────────────────────────────────────────────

    function getAgentSuccessRate(uint256 agentId) external view returns (uint256 bps) {
        Agent storage a = agents[agentId];
        if (a.totalTasks == 0) return 0;
        return (a.successCount * 10_000) / a.totalTasks;
    }

    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "zero address");
        treasury = _treasury;
    }

    function setStakingPool(address _stakingPool) external onlyOwner {
        require(_stakingPool != address(0), "zero address");
        stakingPool = _stakingPool;
    }

    function setInsuranceFund(address _insuranceFund) external onlyOwner {
        require(_insuranceFund != address(0), "zero address");
        insuranceFund = _insuranceFund;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero address");
        owner = newOwner;
    }
}
