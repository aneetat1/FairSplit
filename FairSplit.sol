// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Classroom prototype: one shared-expense pool per deployment.
/// @dev Uses native test ETH. Test thoroughly in Remix VM before Sepolia.
contract FairSplit {
    address public immutable creator;
    bool public initialized;
    bool public closed;
    string public purpose;
    address[] public members;
    mapping(address => bool) public isMember;
    mapping(address => bool) public hasContributed;
    mapping(address => bool) public refundClaimed;

    uint256 public contributionAmount;
    uint256 public fundingDeadline;
    uint256 public endTime;
    uint256 public approvalThreshold;
    uint256 public contributorCount;
    uint256 public poolBalance;
    uint256 public refundPerMember;
    uint256 public refundRemainder;
    address public remainderRecipient;
    bool private entered;

    struct Expense {
        address payable recipient;
        uint256 amount;
        string description;
        uint256 approvals;
        bool executed;
    }
    Expense[] public expenses;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    event PoolCreated(string purpose, uint256 memberCount);
    event Contribution(address indexed member, uint256 amount);
    event ExpenseProposed(uint256 indexed id, address recipient, uint256 amount, string description);
    event VoteCast(uint256 indexed id, address indexed member, bool approve);
    event ExpensePaid(uint256 indexed id, uint256 amount);
    event PoolClosed(uint256 remainingBalance, uint256 refundPerMember);
    event RefundPaid(address indexed member, uint256 amount);

    constructor() {
        creator = msg.sender;
    }

    modifier nonReentrant() {
        require(!entered, "Reentrant call");
        entered = true;
        _;
        entered = false;
    }

    modifier onlyMember() {
        require(isMember[msg.sender], "Members only");
        _;
    }

    modifier activePool() {
        require(initialized && !closed, "Pool unavailable");
        require(block.timestamp < endTime, "Pool has ended");
        require(contributorCount == members.length, "Not fully funded");
        _;
    }

    // KEERTHANA: configure the pool once, then collect equal contributions.
    // Durations are seconds; contributionWei is in wei, not ETH.
    function createPool(
        string calldata poolPurpose,
        address[] calldata poolMembers,
        uint256 contributionWei,
        uint256 fundingDurationSeconds,
        uint256 poolDurationSeconds
    ) external nonReentrant {
        require(msg.sender == creator, "Creator only");
        require(!initialized, "Already initialized");
        require(poolMembers.length >= 2 && poolMembers.length <= 20, "Use 2-20 members");
        require(bytes(poolPurpose).length > 0 && bytes(poolPurpose).length <= 200, "Invalid purpose");
        require(contributionWei > 0, "Contribution must be positive");
        require(fundingDurationSeconds > 0 && poolDurationSeconds > fundingDurationSeconds,
            "Invalid durations");

        for (uint256 i; i < poolMembers.length; i++) {
            address member = poolMembers[i];
            require(member != address(0) && member != address(this), "Invalid member");
            require(!isMember[member], "Duplicate member");
            isMember[member] = true;
            members.push(member);
        }
        purpose = poolPurpose;
        contributionAmount = contributionWei;
        // Strictly more than half of all members, not just those who vote.
        approvalThreshold = poolMembers.length / 2 + 1;
        fundingDeadline = block.timestamp + fundingDurationSeconds;
        endTime = block.timestamp + poolDurationSeconds;
        initialized = true;
        emit PoolCreated(poolPurpose, members.length);
    }

    function contribute() external payable nonReentrant onlyMember {
        require(initialized && !closed, "Pool unavailable");
        require(block.timestamp < fundingDeadline, "Funding ended");
        require(!hasContributed[msg.sender], "Already contributed");
        require(msg.value == contributionAmount, "Send exact contribution");
        hasContributed[msg.sender] = true;
        contributorCount++;
        poolBalance += msg.value;
        if (remainderRecipient == address(0)) remainderRecipient = msg.sender;
        emit Contribution(msg.sender, msg.value);
    }

    // ANEETA: propose, approve/reject, and execute shared expenses.
    function proposeExpense(address payable recipient, uint256 amount, string calldata description)
        external nonReentrant onlyMember activePool returns (uint256 id)
    {
        require(recipient != address(0) && recipient != address(this), "Invalid recipient");
        require(amount > 0 && amount <= poolBalance, "Invalid amount");
        require(bytes(description).length > 0 && bytes(description).length <= 200, "Invalid description");
        id = expenses.length;
        expenses.push(Expense(recipient, amount, description, 0, false));
        emit ExpenseProposed(id, recipient, amount, description);
    }

    // One final vote per member per expense; proposing does not auto-vote.
    function voteOnExpense(uint256 id, bool approve) external nonReentrant onlyMember activePool {
        require(id < expenses.length, "Unknown expense");
        require(!expenses[id].executed, "Already paid");
        require(!hasVoted[id][msg.sender], "Already voted");
        hasVoted[id][msg.sender] = true;
        if (approve) expenses[id].approvals++;
        emit VoteCast(id, msg.sender, approve);
    }

    function executeExpense(uint256 id) external nonReentrant onlyMember activePool {
        require(id < expenses.length, "Unknown expense");
        Expense storage expense = expenses[id];
        require(!expense.executed, "Already paid");
        require(expense.approvals >= approvalThreshold, "Not approved");
        // Proposals do not reserve funds: check available balance again here.
        require(expense.amount <= poolBalance, "Insufficient pool funds");
        expense.executed = true;
        poolBalance -= expense.amount;
        (bool success,) = expense.recipient.call{value: expense.amount}("");
        require(success, "Payment failed");
        emit ExpensePaid(id, expense.amount);
    }

    // JOCELYN: deadline-based closure and individual refund withdrawals.
    // Anyone can finalize closure after the relevant deadline.
    // If funding fails, spending was never enabled; contributors get deposits back.
    function closePool() external nonReentrant {
        require(initialized && !closed, "Pool unavailable");
        bool fundingFailed = block.timestamp >= fundingDeadline && contributorCount < members.length;
        require(fundingFailed || block.timestamp >= endTime, "Too early to close");
        closed = true;
        if (contributorCount > 0) {
            refundPerMember = poolBalance / contributorCount;
            refundRemainder = poolBalance % contributorCount;
        }
        emit PoolClosed(poolBalance, refundPerMember);
    }

    function claimRefund() external nonReentrant onlyMember {
        require(closed, "Close pool first");
        require(hasContributed[msg.sender], "No contribution");
        require(!refundClaimed[msg.sender], "Already refunded");
        refundClaimed[msg.sender] = true;
        uint256 amount = refundPerMember;
        // Allocate rounding dust (less than contributorCount wei) deterministically.
        if (msg.sender == remainderRecipient) amount += refundRemainder;
        poolBalance -= amount;
        if (amount > 0) {
            (bool success,) = payable(msg.sender).call{value: amount}("");
            require(success, "Refund failed");
        }
        emit RefundPaid(msg.sender, amount);
    }

    // Views make the Remix demo easier. Direct ETH transfers are not accepted.
    function getMembers() external view returns (address[] memory) {
        return members;
    }

    function expenseCount() external view returns (uint256) {
        return expenses.length;
    }
}
