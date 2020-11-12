/*

SKI.FINANCE CONTRACTS

Website: https://ski.finance
Original slopes.finance contracts audited by Aegis DAO and Sherlock Security

*/

pragma solidity ^0.6.12;

import './Ownable.sol';
import './SafeMath.sol';
import './SafeERC20.sol';
import './IERC20.sol';
import './IUniswapV2Router02.sol';
import './SLOPES.sol';
import './Yeti.sol';
import './IERC1155.sol';
import './SkiPerks.sol';

// The Everest staking contract becomes active after the max supply it hit, and is where SLOPES-ETH LP token stakers will continue to receive dividends from other projects in the SLOPES ecosystem
contract Everest is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user
    struct UserInfo {
        uint256 staked; // How many SLOPES-ETH LP tokens the user has staked
        uint256 rewardDebt; // Reward debt. Works the same as in the Yeti contract
        uint256 claimed; // Tracks the amount of SLOPES claimed by the user
    }

    // The SLOPES TOKEN!
    SLOPES public slopes;
    // The Yeti contract
    Yeti public yeti;
    // The SLOPES-ETH Uniswap LP token
    IERC20 public slopesPool;
    // The Uniswap v2 Router
    IUniswapV2Router02 public uniswapRouter = IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    // WETH
    IERC20 public weth;

    // Info of each user that stakes SLOPES-ETH LP tokens
    mapping (address => UserInfo) public userInfo;
    // The amount of SLOPES sent to this contract before it became active
    uint256 public initialSlopesReward = 0;
    // 1% of the initialSlopesReward will be rewarded to stakers per day for 100 days
    uint256 public initialSlopesRewardPerDay;
    // How often the initial 1% payouts can be processed
    uint256 public constant INITIAL_PAYOUT_INTERVAL = 24 hours;
    // The unstaking fee that is used to increase locked liquidity and reward Everest stakers (1 = 0.1%). Defaults to 10%
    uint256 public unstakingFee = 100;
    // The amount of SLOPES-ETH LP tokens kept by the unstaking fee that will be converted to SLOPES and distributed to stakers (1 = 0.1%). Defaults to 50%
    uint256 public unstakingFeeConvertToSlopesAmount = 500;
    // When the first 1% payout can be processed (timestamp). It will be 24 hours after the Everest contract is activated
    uint256 public startTime;
    // When the last 1% payout was processed (timestamp)
    uint256 public lastPayout;
    // The total amount of pending SLOPES available for stakers to claim
    uint256 public totalPendingSlopes;
    // Accumulated SLOPES per share, times 1e12.
    uint256 public accSlopesPerShare;
    // The total amount of SLOPES-ETH LP tokens staked in the contract
    uint256 public totalStaked;
    // Becomes true once the 'activate' function called by the Yeti contract when the max SLOPES supply is hit
    bool public active = false;

    event Stake(address indexed user, uint256 amount);
    event Claim(address indexed user, uint256 slopesAmount);
    event Withdraw(address indexed user, uint256 amount);
    event SlopesRewardAdded(address indexed user, uint256 slopesReward);
    event EthRewardAdded(address indexed user, uint256 ethReward);

    constructor(SLOPES _slopes, Yeti _yeti) public {
        yeti = _yeti;
        slopes = _slopes;
        slopesPool = IERC20(yeti.slopesPoolAddress());
        weth = IERC20(uniswapRouter.WETH());
    }

    receive() external payable {
        emit EthRewardAdded(msg.sender, msg.value);
    }

    function activate() public {
        require(active != true, "already active");
        require(slopes.maxSupplyHit() == true, "too soon");

        active = true;

        // Now that the Everest staking contract is active, reward 1% of the initialSlopesReward per day for 100 days
        startTime = block.timestamp + INITIAL_PAYOUT_INTERVAL; // The first payout can be processed 24 hours after activation
        lastPayout = startTime;
        initialSlopesRewardPerDay = initialSlopesReward.div(100);
    }

    // The _transfer function in the SLOPES contract calls this to let the Everest contract know that it received the specified amount of SLOPES to be distributed to stakers
    function addSlopesReward(address _from, uint256 _amount) public {
        require(msg.sender == address(slopes), "not slopes contract");
        require(yeti.slopesPoolActive() == true, "no slopes pool");
        require(_amount > 0, "no slopes");

        if (active != true || totalStaked == 0) {
            initialSlopesReward = initialSlopesReward.add(_amount);
        } else {
            totalPendingSlopes = totalPendingSlopes.add(_amount);
            accSlopesPerShare = accSlopesPerShare.add(_amount.mul(1e12).div(totalStaked));
        }

        emit SlopesRewardAdded(_from, _amount);
    }

    // Allows external sources to add ETH to the contract which is used to buy and then distribute SLOPES to stakers
    function addEthReward() public payable {
        require(yeti.slopesPoolActive() == true, "no slopes pool");

        // We will purchase SLOPES with all of the ETH in the contract in case some was sent directly to the contract instead of using addEthReward
        uint256 ethBalance = address(this).balance;
        require(ethBalance > 0, "no eth");

        // Use the ETH to buyback SLOPES which will be distributed to stakers
        _buySlopes(ethBalance);

        // The _transfer function in the SLOPES contract calls the Everest contract's updateSlopesReward function so we don't need to update the balances after buying the SLOPES
        emit EthRewardAdded(msg.sender, msg.value);
    }

    // Internal function to buy back SLOPES with the amount of ETH specified
    function _buySlopes(uint256 _amount) internal {
        uint256 deadline = block.timestamp + 5 minutes;
        address[] memory slopesPath = new address[](2);
        slopesPath[0] = address(weth);
        slopesPath[1] = address(slopes);
        uniswapRouter.swapExactETHForTokens{value: _amount}(0, slopesPath, address(this), deadline);
    }

    // Handles paying out the initialSlopesReward over 100 days
    function _processInitialPayouts() internal {
        if (active != true || block.timestamp < startTime || initialSlopesReward == 0 || totalStaked == 0) return;

        // How many days since last payout?
        uint256 daysSinceLastPayout = (block.timestamp - lastPayout) / INITIAL_PAYOUT_INTERVAL;

        // If less than 1, don't do anything
        if (daysSinceLastPayout == 0) return;

        // Work out how many payouts have been missed
        uint256 nextPayoutNumber = (block.timestamp - startTime) / INITIAL_PAYOUT_INTERVAL;
        uint256 previousPayoutNumber = nextPayoutNumber - daysSinceLastPayout;

        // Calculate how much additional reward we have to hand out
        uint256 slopesReward = rewardAtPayout(nextPayoutNumber) - rewardAtPayout(previousPayoutNumber);
        if (slopesReward > initialSlopesReward) slopesReward = initialSlopesReward;
        initialSlopesReward = initialSlopesReward.sub(slopesReward);

        // Payout the slopesReward to the stakers
        totalPendingSlopes = totalPendingSlopes.add(slopesReward);
        accSlopesPerShare = accSlopesPerShare.add(slopesReward.mul(1e12).div(totalStaked));

        // Update lastPayout time
        lastPayout += (daysSinceLastPayout * INITIAL_PAYOUT_INTERVAL);
    }

    // Handles claiming the user's pending SLOPES rewards
    function _claimReward(address _user) internal {
        UserInfo storage user = userInfo[_user];
        if (user.staked > 0) {
        // SKISECURE: boost yield for Ski NFT owners

            SkiPerks perks = SkiPerks(yeti.skiPerksAddress());
            uint256 pendingBoost = perks.everestPerks(yeti.nftSkiAddress(), _user);

            uint256 pendingSlopesReward = user.staked.mul(pendingBoost).div(100).mul(accSlopesPerShare).div(1e12).sub(user.rewardDebt);
            if (pendingSlopesReward > 0) {
                totalPendingSlopes = totalPendingSlopes.sub(pendingSlopesReward);
                user.claimed += pendingSlopesReward;
                _safeSlopesTransfer(_user, pendingSlopesReward);
                emit Claim(_user, pendingSlopesReward);
            }
        }
    }

    // Stake SLOPES-ETH LP tokens to get rewarded with more SLOPES
    function stake(uint256 _amount) public {
        stakeFor(msg.sender, _amount);
    }

    // Stake SLOPES-ETH LP tokens on behalf of another address
    function stakeFor(address _user, uint256 _amount) public {
        require(active == true, "not active");
        require(_amount > 0, "stake something");

        _processInitialPayouts();

        // Claim any pending SLOPES
        _claimReward(_user);

        slopesPool.safeTransferFrom(address(msg.sender), address(this), _amount);

        UserInfo storage user = userInfo[_user];
        totalStaked = totalStaked.add(_amount);
        user.staked = user.staked.add(_amount);
        user.rewardDebt = user.staked.mul(accSlopesPerShare).div(1e12);
        emit Stake(_user, _amount);
    }

    // Claim earned SLOPES. Claiming won't work until active == true
    function claim() public {
        require(active == true, "not active");
        UserInfo storage user = userInfo[msg.sender];
        require(user.staked > 0, "no stake");

        _processInitialPayouts();

        // Claim any pending SLOPES
        _claimReward(msg.sender);

        user.rewardDebt = user.staked.mul(accSlopesPerShare).div(1e12);
    }

    // Unstake and withdraw SLOPES-ETH LP tokens and any pending SLOPES rewards. There is a 10% unstaking fee, meaning the user will only receive 90% of their LP tokens back.
    // For the LP tokens kept by the unstaking fee, 50% will get locked forever in the SLOPES contract, and 50% will get converted to SLOPES and distributed to stakers.
    function withdraw(uint256 _amount) public {
        require(active == true, "not active");
        UserInfo storage user = userInfo[msg.sender];
        require(_amount > 0 && user.staked >= _amount, "withdraw: not good");

        _processInitialPayouts();

        uint256 unstakingFeeAmount = _amount.mul(unstakingFee).div(1000);
        uint256 remainingUserAmount = _amount.sub(unstakingFeeAmount);

        // Half of the LP tokens kept by the unstaking fee will be locked forever in the SLOPES contract, the other half will be converted to SLOPES and distributed to stakers
        uint256 lpTokensToConvertToSlopes = unstakingFeeAmount.mul(unstakingFeeConvertToSlopesAmount).div(1000);
        uint256 lpTokensToLock = unstakingFeeAmount.sub(lpTokensToConvertToSlopes);

        // Remove the liquidity from the Uniswap SLOPES-ETH pool and buy SLOPES with the ETH received
        // The _transfer function in the SLOPES.sol contract automatically calls everest.addSlopesReward() so we don't have to in this function
        if (lpTokensToConvertToSlopes > 0) {
            slopesPool.approve(address(uniswapRouter), lpTokensToConvertToSlopes);
            uniswapRouter.removeLiquidityETHSupportingFeeOnTransferTokens(address(slopes), lpTokensToConvertToSlopes, 0, 0, address(this), block.timestamp + 5 minutes);
            addEthReward();
        }

        // Permanently lock the LP tokens in the SLOPES contract
        if (lpTokensToLock > 0) slopesPool.transfer(address(slopes), lpTokensToLock);

        // Claim any pending SLOPES
        _claimReward(msg.sender);

        totalStaked = totalStaked.sub(_amount);
        user.staked = user.staked.sub(_amount);
        slopesPool.safeTransfer(address(msg.sender), remainingUserAmount);
        user.rewardDebt = user.staked.mul(accSlopesPerShare).div(1e12);
        emit Withdraw(msg.sender, remainingUserAmount);
    }

    // Internal function to safely transfer SLOPES in case there is a rounding error
    function _safeSlopesTransfer(address _to, uint256 _amount) internal {
        uint256 slopesBal = slopes.balanceOf(address(this));
        if (_amount > slopesBal) {
            slopes.transfer(_to, slopesBal);
        } else {
            slopes.transfer(_to, _amount);
        }
    }

    // Sets the unstaking fee. Can't be higher than 50%. _convertToSlopesAmount is the % of the LP tokens from the unstaking fee that will be converted to SLOPES and distributed to stakers.
    // unstakingFee - unstakingFeeConvertToSlopesAmount = The % of the LP tokens from the unstaking fee that will be permanently locked in the SLOPES contract
    function setUnstakingFee(uint256 _unstakingFee, uint256 _convertToSlopesAmount) public onlyOwner {
        require(_unstakingFee <= 500, "over 50%");
        require(_convertToSlopesAmount <= 1000, "bad amount");
        unstakingFee = _unstakingFee;
        unstakingFeeConvertToSlopesAmount = _convertToSlopesAmount;
    }

    // Function to recover ERC20 tokens accidentally sent to the contract.
    // SLOPES and SLOPES-ETH LP tokens (the only 2 ERC2O's that should be in this contract) can't be withdrawn this way.
    function recoverERC20(address _tokenAddress) public onlyOwner {
        require(_tokenAddress != address(slopes) && _tokenAddress != address(slopesPool));
        IERC20 token = IERC20(_tokenAddress);
        uint256 tokenBalance = token.balanceOf(address(this));
        token.transfer(msg.sender, tokenBalance);
    }

    function payoutNumber() public view returns (uint256) {
        if (block.timestamp < startTime) return 0;

        uint256 payout = (block.timestamp - startTime).div(INITIAL_PAYOUT_INTERVAL);
        if (payout > 100) return 100;
        else return payout;
    }

    function timeUntilNextPayout() public view returns (uint256) {
        if (initialSlopesReward == 0) return 0;
        else {
            uint256 payout = payoutNumber();
            uint256 nextPayout = startTime.add((payout + 1).mul(INITIAL_PAYOUT_INTERVAL));
            return nextPayout - block.timestamp;
        }
    }

    function rewardAtPayout(uint256 _payoutNumber) public view returns (uint256) {
        if (_payoutNumber == 0) return 0;
        return initialSlopesRewardPerDay * _payoutNumber;
    }

    function getAllInfoFor(address _user) external view returns (bool isActive, uint256[12] memory info) {
        isActive = active;
        info[0] = slopes.balanceOf(address(this));
        info[1] = initialSlopesReward;
        info[2] = totalPendingSlopes;
        info[3] = startTime;
        info[4] = lastPayout;
        info[5] = totalStaked;
        info[6] = slopes.balanceOf(_user);
        if (yeti.slopesPoolActive()) {
            info[7] = slopesPool.balanceOf(_user);
            info[8] = slopesPool.allowance(_user, address(this));
        }
        info[9] = userInfo[_user].staked;
        SkiPerks perks = SkiPerks(yeti.skiPerksAddress());
        uint256 pendingBoost = perks.everestPerks(yeti.nftSkiAddress(), _user);
        info[10] = userInfo[_user].staked.mul(pendingBoost).div(100).mul(accSlopesPerShare).div(1e12).sub(userInfo[_user].rewardDebt);
        info[11] = userInfo[_user].claimed;
    }

}
