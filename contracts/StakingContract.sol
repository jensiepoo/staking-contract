// SPDX-License-Identifier: MIT
pragma solidity 0.8.11;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-solidity/contracts/utils/math/SafeMath.sol";

/// @title A drip-feed system erc20 staking contract
/// @author The holloway brothers
/// @notice The user gets a certain amount of the contracts rewards supply distributed to them every block
/// based on their staked amount * RewardRate. The contract has to be loaded with funds to distribute
///
/// If the contract runs out of funds, it will return zero rewards for all users until more rewards are added.
/// If the contract runs out of rewards no one will be able to stake, or claim. They will be able to unstake though.
/// When they unstake, it will not update their time in the pool. So if the contract owner deposits funds
/// they may then claim their rewards pending BASED ON THEIR CURRENT BALANCE STILL STAKED at claim time
///
/// The contract will reflect 0 rewards when the total minted is below the reward supply
/// The contract only distributes the token provided in the constructor
contract StakingContract {

    struct RewardChange {
        uint256 time;
        uint256 cycleRate;
    }

    // boolean to prevent reentrancy
    bool internal locked;

    // Library usage
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // Contract owner
    address public owner;

    // Timestamp related variables
    uint256 public initialTimestamp;
    bool public timestampSet;
    uint256 public timePeriod;

    // Contract info variables
    uint256 public totalStaked;
    uint256 public contractBalanceEth;
    uint256 public totalMinted;
    uint256 public contractTokenBalance;
    uint256 public rewardsSupply;
    uint256 public rewardRate;
    uint256 public currentRewardPeriodId;
    uint256 public fee = 4;
    uint256 public devFee = 4;
    uint256 public totalFee = fee + devFee;
    address private devFeeAddress = payable(0xD61a83BBef2933B5b19B779D124faa4e936B486e);
    address public managerAddress;
    uint256 public rewardsWithoutFee;
    uint256 public rewardsWithManagerFee;
    uint256 public rewardsWithDevFee;
    uint256 private MAX_INT = 2**256 - 1;

    //Mappings
    mapping(address => uint256) public alreadyWithdrawn;
    mapping(address => uint256) public balances;
    mapping(address => uint256) public rewardsForUser;
    mapping(address => uint256) public lastUpdateTime;
    mapping(address => uint256) private devAccruedFee;
    mapping(address => uint256) public managerAccruedFee;
    mapping(address => uint256) public userRewardRateCycle;
    mapping(uint256 => RewardChange) public rewardCycle;
    uint256[] public currentRewardPeriod;

    // ERC20 contract address
    IERC20 public erc20Contract;

    // Events
    event TokensStaked(address from, uint256 amount);
    event TokensUnstaked(address to, uint256 amount);
    event ClaimedRewards(address to, uint256 amount);

    /// @dev Deploys contract and links the ERC20 token which we are staking, also sets owner as
    /// msg.sender and sets timestampSet bool to false.

    /// @param erc20ContractAddress.
    /// @param rewardRate (eg. 31,000,000) - 100% apr approx
    /// @param managerAddresss ( Fees sent to this address)
    constructor(IERC20 erc20ContractAddress, uint256 _rewardRate, address _managerAddress) {
        owner = msg.sender;

        // Set the erc20 contract address which this timelock is deliberately paired to
        require(address(erc20ContractAddress) != address(0), "erc20ContractAddress address can not be zero.");
        erc20Contract = erc20ContractAddress;

        // recommend setting to 33,000,000 which is 100% apr approximate
        rewardRate = _rewardRate;
        managerAddress = _managerAddress;
        locked = false;
    }

    /// @dev Prevents reentrancy
    modifier noReentrant() {
        require(!locked, "No re-entrancy.");
        locked = true;
        _;
        locked = false;
    }

    modifier validAccount(address account) {
        require(account != address(0), "Account has to be valid.");
        _;
    }

    /// @dev setrewardsfor user to the recently claimed balance (need to rename function).
    modifier updateRewardsBalance(address account) {
        if (account != address(0)) {
            rewardsForUser[account] = setRewardsForUser(account);
        }
        _;
    }

    /// Claims user rewards upon stake, unstake.
    modifier ClaimUserRewards(IERC20 token) {
        if (contractTokenBalance < rewardsSupply) {
            revealRewards(msg.sender);
        }
        if (revealRewards(msg.sender) > 0) {
            claimTokens(token);
        } else {
            revealRewards(msg.sender);
        }
        _;
    }

    /// @dev Throws if not called by owner.
    modifier onlyOwner() {
        require(msg.sender == owner, "Message sender must be the contract's owner.");
        _;
    }

    /// @dev Throws if not called by pool manager address provided in constructor.
    modifier onlyManager() {
        require(msg.sender == managerAddress, "Message sender must be the contract's owner.");
        _;
    }

    /// @dev Throws if not called by hardcoded dev address.
    modifier onlyDev() {
        require(msg.sender == devFeeAddress, "Only Dev can pull fees.");
        _;
    }

    /// @dev Throws if timestamp already set.
    modifier timestampNotSet() {
        require(timestampSet == false, "The time stamp has already been set.");
        _;
    }

    /// @dev Throws if timestamp not set.
    modifier timestampIsSet() {
        require(timestampSet == true, "Please set the time stamp first, then try again.");
        _;
    }

    function updateRewardCycle(uint index, uint256 cycleRate) private {
        rewardCycle[index].time = now();
        rewardCycle[index].cycleRate = cycleRate;
    }

    // set reward rate to 1,000,000 for an apr of around 3%  on deposit
    // set rewardrate to 33,000,000 for 100%
    // set reward rate to 500,000 for an apr of 100% on deposit  = 2000$ minted to user
    // balance(2000).div(1,000,000) x (secondsinpool (31.5 million peryear) = $4000 in rewards minted to user
    function setRewardRate(uint256 amount) external onlyOwner {
        require(contractTokenBalance > 1, "Set the erc20 balance first before changing reward rate.");
        updateRewardCycle(currentRewardPeriodId.add(1), amount);
        rewardRate = amount * 1e18;
        //recommend 31,000,000 for 100%apr
    }

    /// @notice autocompound = run normal transaction but instead of claiming and putting into users waller
    /// you claim 5% max fee thus apr% is 5% less then RewardRate
    function setFee(uint256 feePercentage) external onlyManager {
        require(feePercentage < 8, "Cannot set fees above 8% sir or madam, it's just not reasonable.");
        fee = feePercentage;
    }

    function updateTime(address account) private validAccount {
        lastUpdateTime[account] = now();
    }

    function updateUsersRewardCycle(address account) private validAccount {
        userRewardRateCycle[account] = currentRewardPeriodId;
    }

    // The boys need beer money sir
    function collectDevFee(IERC20 token) external onlyDev {
        approveERC20(msg.sender, MAX_INT);
        token.safeTransfer(msg.sender, devAccruedFee[msg.sender]);
    }

    function collectManagerFee(IERC20 token) external onlyManager {
        approveERC20(msg.sender, MAX_INT);
        token.safeTransfer(msg.sender, managerAccruedFee[msg.sender]);
    }

    function checkERCBal() external view returns (uint256) {
        IERC20 token = IERC20(erc20Contract);
        return token.balanceOf(address(this));
    }

    function setRewardBal() external onlyManager returns (uint256) {
        IERC20 token = IERC20(erc20Contract);
        updateRewardCycle(currentRewardPeriodId.add(1), RewardRate);
        contractTokenBalance = token.balanceOf(address(this));
        rewardsSupply = contractTokenBalance.sub(totalMinted);
        return rewardsSupply;
    }

    /// @dev Sets the initial timestamp and calculates minimum staking period in seconds, i.e. 3600 = 1 hour
    /// @param timePeriodInSeconds amount of seconds to add to the initial timestamp i.e. we are essentially creating the minimum staking period here
    function setTimestamp(uint256 timePeriodInSeconds) public onlyOwner timestampNotSet {
        require(timePeriodInSeconds > 899, "To account for potential 900 second error of block.timestamp you must set timestamp to minimum 900 seconds");
        timestampSet = true;
        initialTimestamp = now();
        timePeriod = initialTimestamp.add(timePeriodInSeconds);
    }

    /// @param timePeriodInSeconds amount of seconds to add to the initial timestamp i.e. we are essentially creating the minimum staking period here
    function setMinimumStakingPeriod(uint256 minimumStakingPeriodInSeconds) external onlyOwner timestampNotSet {
        require(timePeriodInSeconds > 899, "To account for potential 900 second error of block.timestamp you must set timestamp to minimum 900 seconds");
        initialTimestamp = now();
        timePeriod = initialTimestamp.add(timePeriodInSeconds);
    }

    function now() internal view returns (uint256) {
        // Note that the timestamp can have a 900-second error:
        // https://github.com/ethereum/wiki/blob/c02254611f218f43cbb07517ca8e5d00fd6d6d75/Block-Protocol-2.0.md
        return block.timestamp;
        // solium-disable-line security/no-block-members
    }

    function setRewardsForUser(address account) internal returns (uint256) {
        return rewardsForUser[account] = revealRewards(account);
    }

    function revealFee(address account) public view returns (uint256) {
        if (balances[account] < 0) {
            return 0;
        } else if (userRewardRateCycle[account] == 0) {
            return totalFee.mul(balances[account].div(RewardRate).mul(block.timestamp - lastUpdateTime[account])).div(1e4);
        } else {
            return totalFee.mul(balances[account].div(rewardCycle[userRewardRateCycle[account]].cycleRate).mul(block.timestamp - lastUpdateTime[account])).div(1e4);
        }
    }

    function revealRewards(address account) public view returns (uint256) {
        if (totalStaked > rewardsSupply) {
            return 0;
        } else if (userRewardRateCycle[account] == 0) {
            return balances[account].div(RewardRate).mul(block.timestamp - lastUpdateTime[account]).sub((totalFee).mul(balances[account].div((RewardRate).mul(block.timestamp - lastUpdateTime[account]))).div(1e3));

        } else {
            return balances[account].div(rewardCycle[userRewardRateCycle[account]].cycleRate).mul(block.timestamp - lastUpdateTime[account]).sub((totalFee).mul(balances[account].div(rewardCycle[userRewardRateCycle[account]].cycleRate.mul(block.timestamp - lastUpdateTime[account]))).div(1e3));
        }
    }

    /// @notice Check the users time in the pool.
    function checkTimeInPool(address account) external view returns (uint256) {
        return block.timestamp - lastUpdateTime[account];
    }

    /// @notice Fetch manager fee.
    function fetchFee() external view returns (uint256){
        return fee;
    }

    function approveERC20(address spender, uint256 amount) public returns (bool) {
        IERC20 token = IERC20(erc20Contract);
        token.approve(spender, amount);
        return true;
    }

    function compound(IERC20 token) public timestampIsSet noReentrant {
        require(token == erc20Contract, "You are only allowed to withdraw the official erc20 token address which was passed into this contract's constructor");
        require(contractTokenBalance > totalMinted, "Not enough Rewards in the Pool.");
        approveERC20(msg.sender, MAX_INT);
        contractTokenBalance = token.balanceOf(address(this));
        managerAccruedFee[managerAddress] = managerAccruedFee[managerAddress].add(revealRewards(msg.sender).mul(fee));
        devAccruedFee[devFeeAddress] = devAccruedFee[devFeeAddress].add(revealRewards(msg.sender).mul(devFee));
        totalStaked = totalStaked.add(revealRewards(msg.sender));
        totalMinted = totalMinted.add(revealRewards(msg.sender));
        balances[msg.sender] = balances[msg.sender].add(revealRewards(msg.sender));
        setRewardsForUser(msg.sender);
        updateTime(msg.sender);
        updateUsersRewardCycle(msg.sender);
        emit ClaimedRewards(msg.sender, rewardsForUser[msg.sender]);
    }

    /// @param token - ERC20 token address. must claim whole balance
    function claimTokens(IERC20 token) public timestampIsSet noReentrant {
        require(token == erc20Contract, "You are only allowed to compound the official erc20 token address which was passed into this contract's constructor");
        require(contractTokenBalance > totalMinted, "Not enough Rewards in the Pool.");
        approveERC20(msg.sender, MAX_INT);
        contractTokenBalance = token.balanceOf(address(this));
        managerAccruedFee[managerAddress] = managerAccruedFee[managerAddress].add(revealRewards(msg.sender).mul(fee));
        devAccruedFee[devFeeAddress] = devAccruedFee[devFeeAddress].add(revealRewards(msg.sender).mul(devFee));
        setRewardsForUser(msg.sender);
        updateTime(msg.sender);
        updateUsersRewardCycle(msg.sender);

        token.safeTransfer(msg.sender, rewardsForUser[msg.sender]);
        emit ClaimedRewards(msg.sender, rewardsForUser[msg.sender]);
    }

    /// @param token - ERC20 token address.
    /// @param amount of ERC20 tokens to add.
    function stakeTokens(IERC20 token, uint256 amount) public ClaimUserRewards(token) timestampIsSet noReentrant {
        require(token == erc20Contract, "You are only allowed to stake the official erc20 token address which was passed into this contract's constructor");
        require(amount <= token.balanceOf(msg.sender), "Not enough tokens in your wallet, please try lesser amount");
        require(amount > 1, "Minimum deposit of one token");
        if (contractTokenBalance < rewardsSupply) {
            revert("Contract owner needs to deposit funds");
        } else {
            contractTokenBalance = token.balanceOf(address(this));
            updateTime(msg.sender);
            updateUsersRewardCycle(msg.sender);
            balances[msg.sender] = balances[msg.sender].add(amount);
            totalStaked = totalStaked.add(amount);
            totalMinted = totalMinted.add(amount);
            token.safeTransferFrom(msg.sender, address(this), amount);
            emit TokensStaked(msg.sender, amount);

        }
    }

    /// @param token - ERC20 token address.
    /// @param amount of ERC20 tokens to remove.
    function unstakeTokens(IERC20 token, uint256 amount) public ClaimUserRewards(token) timestampIsSet noReentrant {
        require(token == erc20Contract, "You are only allowed to stake the official erc20 token address which was passed into this contract's constructor");
        require(balances[msg.sender] >= amount, "Not enough tokens Staked, please try lesser amount");
        require(block.timestamp >= timePeriod, "You cannot pull out your stake until timeperiod has ended");

        if (contractTokenBalance < rewardsSupply) {
            contractTokenBalance = token.balanceOf(address(this));
            balances[msg.sender] = balances[msg.sender].sub(amount);
            totalStaked = totalStaked.sub(amount);
            totalMinted = totalMinted.sub(amount);
            updateUsersRewardCycle(msg.sender);
            // this will update the users reward rate but will not claim rewards
            token.safeTransfer(msg.sender, amount);
            emit TokensUnstaked(msg.sender, amount);
        } else {
            contractTokenBalance = token.balanceOf(address(this));
            updateTime(msg.sender);
            balances[msg.sender] = balances[msg.sender].sub(amount);
            totalStaked = totalStaked.sub(amount);
            updateUsersRewardCycle(msg.sender);
            totalMinted = totalMinted.sub(amount);
            token.safeTransfer(msg.sender, amount);
            emit TokensUnstaked(msg.sender, amount);

        }
    }

    /// @dev Transfer accidentally locked ERC20 tokens.
    /// @param token - ERC20 token address.
    /// @param amount of ERC20 tokens to remove.
    function transferAccidentallyLockedTokens(IERC20 token, uint256 amount) public onlyOwner noReentrant {
        require(address(token) != address(0), "Token address can not be zero");
        // This function can not access the official timelocked tokens; just other random ERC20 tokens that may have been accidently sent here
        require(token != erc20Contract, "Token address can not be ERC20 address which was passed into the constructor");
        // Transfer the amount of the specified ERC20 tokens, to the owner of this contract
        token.safeTransfer(owner, amount);
    }
}
