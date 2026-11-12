// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Classroom prototype: one shared-expense pool per deployment.
/// @dev Uses native test ETH. Test thoroughly in Remix VM before Sepolia.
contract FairSplit {
    address public immutable creator;
    bool public initialized;
    bool public closed;
    bool public active;
    string public purpose;
    address[] public members;
    mapping(address => bool) public isMember;
    mapping(address => bool) public hasContributed;
    mapping(address => bool) public refundClaimed;
    mapping(address => bool) public hasVotedToProceed;
    uint256 public proceedApprovals;
    uint256 public proceedRejections;
    uint256 public closeApprovals;
    mapping(address => bool) public hasVotedToClose;

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
    event ProceedVoteCast(address indexed member, bool approve);
    event PoolActivated(uint256 memberCount, uint256 approvalsRequired);
    event CloseVoteCast(address indexed member, uint256 approvals, uint256 requiredApprovals);

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
        require(active, "Pool not activated");
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
        // A fully funded pool can start immediately, without a continuation vote.
        if (contributorCount == members.length) {
            active = true;
            emit PoolActivated(members.length, approvalThreshold);
        }
    }

    // After funding closes, only contributors vote on proceeding with fewer members.
    // One final vote each; a strict majority of ALL contributors must approve.
    // The vote expires at endTime; no spending is possible before activation.
    function voteToProceed(bool approve) external nonReentrant onlyMember {
        require(initialized && !closed && !active, "Vote unavailable");
        require(block.timestamp >= fundingDeadline, "Funding still open");
        require(block.timestamp < endTime, "Voting expired");
        require(contributorCount >= 2, "Need at least two contributors");
        require(hasContributed[msg.sender], "Contributors only");
        require(!hasVotedToProceed[msg.sender], "Already voted");
        uint256 needed = contributorCount / 2 + 1;
        require(proceedRejections <= contributorCount - needed, "Continuation rejected");

        hasVotedToProceed[msg.sender] = true;
        if (approve) proceedApprovals++;
        else proceedRejections++;
        emit ProceedVoteCast(msg.sender, approve);

        if (proceedApprovals >= needed) {
            // Compact the bounded member list, preserving contributor order.
            uint256 paidIndex;
            uint256 originalLength = members.length;
            for (uint256 i; i < originalLength; i++) {
                address member = members[i];
                if (hasContributed[member]) {
                    members[paidIndex] = member;
                    paidIndex++;
                } else {
                    isMember[member] = false;
                }
            }
            while (members.length > paidIndex) members.pop();
            approvalThreshold = needed;
            active = true;
            emit PoolActivated(members.length, approvalThreshold);
        }
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

    // JOCELYN: early closure voting, deadline closure, and refund withdrawals.
    // Voting opens after funding ends, or earlier if everyone has paid.
    // Only paid contributors count; after activation these are all active members.
    // The electorate is fixed once voting opens. Each contributor gets one vote.
    // Closure also prevents approved-but-unexecuted expenses from being paid.
    function voteToClose() external nonReentrant onlyMember {
        require(initialized && !closed, "Pool unavailable");
        require(block.timestamp >= fundingDeadline || active, "Funding still open");
        require(block.timestamp < endTime, "Use closePool after end time");
        require(hasContributed[msg.sender], "Contributors only");
        require(!hasVotedToClose[msg.sender], "Already voted to close");
        hasVotedToClose[msg.sender] = true;
        closeApprovals++;
        uint256 needed = closeApprovalThreshold();
        emit CloseVoteCast(msg.sender, closeApprovals, needed);
        // The deciding vote closes immediately, enabling individual refunds.
        if (closeApprovals >= needed) _closePool();
    }

    function closeApprovalThreshold() public view returns (uint256) {
        if (contributorCount == 0) return 0;
        return contributorCount / 2 + 1;
    }

    // Anyone may close at endTime, including if a continuation vote expires.
    // Earlier refunds are available if fewer than two paid, or enough contributors
    // rejected continuation that a majority approval is mathematically impossible.
    function closePool() external nonReentrant {
        require(initialized && !closed, "Pool unavailable");
        bool cannotProceed;
        if (!active && block.timestamp >= fundingDeadline) {
            if (contributorCount < 2) {
                cannotProceed = true;
            } else {
                uint256 needed = contributorCount / 2 + 1;
                cannotProceed = proceedRejections > contributorCount - needed;
            }
        }
        require(cannotProceed || block.timestamp >= endTime, "Too early to close");
        _closePool();
    }

    // Both closure paths freeze spending and snapshot refund shares here.
    function _closePool() internal {
        closed = true;
        active = false;
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
