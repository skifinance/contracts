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
import './UniStakingInterfaces.sol';
import './SLOPES.sol';
import './Everest.sol';
import './IERC1155.sol';
import './SkiPerks.sol';

// Yeti is the master of SLOPES. He can make SLOPES, is a fair guy, and a great instructor.
contract Yeti is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 staked; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 uniRewardDebt; // UNI staking reward debt. See explanation below.
        uint256 claimed; // Tracks the amount of SLOPES claimed by the user.
        uint256 uniClaimed; // Tracks the amount of UNI claimed by the user.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 token; // Address of token contract.
        IERC20 lpToken; // Address of LP token contract.
        uint256 apr; // Fixed APR for the pool. Determines how many SLOPESs to distribute per block.
        uint256 lastSlopesRewardBlock; // Last block number that SLOPES rewards were distributed.
        uint256 accSlopesPerShare; // Accumulated SLOPESs per share, times 1e12. See below.
        uint256 accUniPerShare; // Accumulated UNIs per share, times 1e12. See below.
        address uniStakeContract; // Address of UNI staking contract (if applicable).
    }

    // We do some fancy math here. Basically, any point in time, the amount of SLOPESs
    // entitled to a user but is pending to be distributed is:
    //
    //   pending reward = (user.staked * pool.accSlopesPerShare) - user.rewardDebt
    //
    // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
    //   1. The pool's `accSlopesPerShare` (and `lastSlopesRewardBlock`) gets updated.
    //   2. User receives the pending reward sent to his/her address.
    //   3. User's `staked` amount gets updated.
    //   4. User's `rewardDebt` gets updated.

    // The SLOPES TOKEN!
    SLOPES public slopes;
    // The address of the SLOPES-ETH Uniswap pool
    address public slopesPoolAddress;
     // The Everest staking contract
    Everest public everest;
    // The Uniswap v2 Router
    IUniswapV2Router02 internal uniswapRouter = IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    // The UNI Staking Rewards Factory
    StakingRewardsFactory internal uniStakingFactory = StakingRewardsFactory(0x3032Ab3Fa8C01d786D29dAdE018d7f2017918e12);
    // The UNI Token
    IERC20 internal uniToken = IERC20(0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984);
    // The WETH Token
    IERC20 internal weth;
    // Dev address
    address payable public devAddress;
    //SKISECURE: NFT Ski address for farming perks
    address public nftSkiAddress;
    //SKISECURE: contract defining logic for NFT yield boosting
    address public skiPerksAddress;


    // Info of each pool.
    PoolInfo[] public poolInfo;
    mapping(address => bool) public existingPools;
    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Mapping of whitelisted contracts so that certain contracts like the Aegis pool can interact with the Yeti contract
    mapping(address => bool) public contractWhitelist;
    // The block number when SLOPES mining starts.
    uint256 public startBlock;
    // Becomes true once the SLOPES-ETH Uniswap is created (no sooner than 500 blocks after launch)
    bool public slopesPoolActive = false;
    // The staking fees collected during the first 500 blocks will seed the SLOPES-ETH Uniswap pool
    uint256 public initialSlopesPoolETH  = 0;
    // 5% of every deposit into any secondary pool (not SLOPES-ETH) will be converted to SLOPES (on Uniswap) and sent to the Everest staking contract which becomes active and starts distributing the accumulated SLOPES to stakers once the max supply is hit
    uint256 public slopesSentToEverest = 0;
    // The amount of ETH donated to the SLOPES community by partner projects
    uint256 public donatedETH = 0;
    // Certain partner projects need to donate 25 ETH to the SLOPES community to get a beach
    uint256 public minimumDonationAmount = 25 * 10**18;
    // Mapping of addresses that donated ETH on behalf of a partner project
    mapping(address => address) public donaters;
    // Mapping of the size of donations from partner projects
    mapping(address => uint256) public donations;
    // Approximate number of blocks per year - assumes 13 second blocks
    uint256 internal constant APPROX_BLOCKS_PER_YEAR  = uint256(uint256(365 days) / uint256(13 seconds));
    // The default APR for each pool will be 1,000%
    uint256 internal constant DEFAULT_APR = 1000;
    // There will be a 1000 block Soft Launch in which SLOPES is minted to each pool at a static rate to make the start as fair as possible
    // SKISECURE: double the Soft Launch period to ~4 hours to ensure fair distribution at launch
    uint256 internal constant SOFT_LAUNCH_DURATION = 2000;
    // During the Soft Launch, all pools except for the SLOPES-ETH pool will mint 20 SLOPES per block. Once it's activated, the SLOPES-ETH pool will mint the same amount of SLOPES per block as all of the other pools combined until the end of the Soft Launch
    uint256 internal constant SOFT_LAUNCH_SLOPES_PER_BLOCK = 20 * 10**18;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Claim(address indexed user, uint256 indexed pid, uint256 slopesAmount, uint256 uniAmount);
    event ClaimAll(address indexed user, uint256 slopesAmount, uint256 uniAmount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event SlopesBuyback(address indexed user, uint256 ethSpentOnSlopes, uint256 slopesBought);
    event SlopesPoolActive(address indexed user, uint256 slopesLiquidity, uint256 ethLiquidity);


    constructor(
        SLOPES _slopes,
        address payable _devAddress,
        uint256 _startBlock,
        address _nftSkiAddress,
        address _skiPerksAddress
    ) public {
        slopes = _slopes;
        devAddress = _devAddress;
        startBlock = _startBlock;
        nftSkiAddress = _nftSkiAddress;
        skiPerksAddress = _skiPerksAddress;
        weth = IERC20(uniswapRouter.WETH());

        // Calculate the address the SLOPES-ETH Uniswap pool will exist at
        address uniswapfactoryAddress = uniswapRouter.factory();
        address slopesAddress = address(slopes);
        address wethAddress = address(weth);

        // token0 must be strictly less than token1 by sort order to determine the correct address
        (address token0, address token1) = slopesAddress < wethAddress ? (slopesAddress, wethAddress) : (wethAddress, slopesAddress);

        slopesPoolAddress = address(uint(keccak256(abi.encodePacked(
            hex'ff',
            uniswapfactoryAddress,
            keccak256(abi.encodePacked(token0, token1)),
            hex'96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f'
        ))));

        _addInitialPools();
    }

    receive() external payable {}

    // Internal function to add a new LP Token pool
    function _addPool(address _token, address _lpToken) internal {

        uint256 apr = DEFAULT_APR;
        if (_token == address(slopes)) apr = apr * 5;

        uint256 lastSlopesRewardBlock = block.number > startBlock ? block.number : startBlock;

        poolInfo.push(
            PoolInfo({
                token: IERC20(_token),
                lpToken: IERC20(_lpToken),
                apr: apr,
                lastSlopesRewardBlock: lastSlopesRewardBlock,
                accSlopesPerShare: 0,
                accUniPerShare: 0,
                uniStakeContract: address(0)
            })
        );

        existingPools[_lpToken] = true;
    }

    // Internal function that adds all of the pools that will be available at launch. Called by the constructor
    function _addInitialPools() internal {

        _addPool(address(slopes), slopesPoolAddress); // SLOPES-ETH

        _addPool(0xdAC17F958D2ee523a2206206994597C13D831ec7, 0x0d4a11d5EEaaC28EC3F61d100daF4d40471f1852); // ETH-USDT
        _addPool(0x6B175474E89094C44Da98b954EedeAC495271d0F, 0xA478c2975Ab1Ea89e8196811F51A7B7Ade33eB11); // DAI-ETH
        _addPool(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, 0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc); // USDC-ETH
        _addPool(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599, 0xBb2b8038a1640196FbE3e38816F3e67Cba72D940); // WBTC-ETH
        _addPool(0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984, 0xd3d2E2692501A5c9Ca623199D38826e513033a17); // UNI-ETH
        _addPool(0x514910771AF9Ca656af840dff83E8264EcF986CA, 0xa2107FA5B38d9bbd2C461D6EDf11B11A50F6b974); // LINK-ETH
        _addPool(0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9, 0xDFC14d2Af169B0D36C4EFF567Ada9b2E0CAE044f); // AAVE-ETH
        _addPool(0xC011a73ee8576Fb46F5E1c5751cA3B9Fe0af2a6F, 0x43AE24960e5534731Fc831386c07755A2dc33D47); // SNX-ETH
        _addPool(0x9f8F72aA9304c8B593d555F12eF6589cC3A579A2, 0xC2aDdA861F89bBB333c90c492cB837741916A225); // MKR-ETH
        _addPool(0xc00e94Cb662C3520282E6f5717214004A7f26888, 0xCFfDdeD873554F362Ac02f8Fb1f02E5ada10516f); // COMP-ETH
        _addPool(0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e, 0x2fDbAdf3C4D5A8666Bc06645B8358ab803996E28); // YFI-ETH
        _addPool(0xba100000625a3754423978a60c9317c58a424e3D, 0xA70d458A4d9Bc0e6571565faee18a48dA5c0D593); // BAL-ETH
        _addPool(0x1494CA1F11D487c2bBe4543E90080AeBa4BA3C2b, 0x4d5ef58aAc27d99935E5b6B4A6778ff292059991); // DPI-ETH
        _addPool(0xD46bA6D942050d489DBd938a2C909A5d5039A161, 0xc5be99A02C6857f9Eac67BbCE58DF5572498F40c); // AMPL-ETH
        _addPool(0x2b591e99afE9f32eAA6214f7B7629768c40Eeb39, 0x55D5c232D921B9eAA6b37b5845E439aCD04b4DBa); // HEX-ETH
        _addPool(0x93ED3FBe21207Ec2E8f2d3c3de6e058Cb73Bc04d, 0x343FD171caf4F0287aE6b87D75A8964Dc44516Ab); // PNK-ETH
        _addPool(0x429881672B9AE42b8EbA0E26cD9C73711b891Ca5, 0xdc98556Ce24f007A5eF6dC1CE96322d65832A819); // PICKLE-ETH
        _addPool(0x84294FC9710e1252d407d3D80A84bC39001bd4A8, 0x0C5136B5d184379fa15bcA330784f2d5c226Fe96); // NUTS-ETH
        _addPool(0x821144518dfE9e7b44fCF4d0824e15e8390d4637, 0x490B5B2489eeFC4106C69743F657e3c4A2870aC5); // ATIS-ETH
        _addPool(0xB9464ef80880c5aeA54C7324c0b8Dd6ca6d05A90, 0xa8D0f6769AB020877f262D8Cd747c188D9097d7E); // LOCK-ETH
        _addPool(0x926dbD499d701C61eABe2d576e770ECCF9c7F4F3, 0xC7c0EDf0b5f89eff96aF0E31643Bd588ad63Ea23); // aDAO-ETH
        _addPool(0x3A9FfF453d50D4Ac52A6890647b823379ba36B9E, 0x260E069deAd76baAC587B5141bB606Ef8b9Bab6c); // SHUF-ETH
        _addPool(0x9720Bcf5a92542D4e286792fc978B63a09731CF0, 0x08538213596fB2c392e9c5d4935ad37645600a57); // OTBC-ETH
        _addPool(0xEEF9f339514298C6A857EfCfC1A762aF84438dEE, 0x23d15EDceb5B5B3A23347Fa425846DE80a2E8e5C); // HEZ-ETH

        // These beaches will be manually added after their teams make the 25 ETH donation
        // _addPool(0x6F87D756DAf0503d08Eb8993686c7Fc01Dc44fB1, 0xd2E0C4928789e5DB620e53af29F5fC7bcA262635); // TRADE-ETH

    }

    // Get the pending SLOPESs for a user from 1 pool
    function _pendingSlopes(uint256 _pid, address _user) internal view returns (uint256) {
        if (_pid == 0 && slopesPoolActive != true) return 0;

        PoolInfo memory pool = poolInfo[_pid];
        UserInfo memory user = userInfo[_pid][_user];
        uint256 accSlopesPerShare = pool.accSlopesPerShare;
        uint256 lpSupply = _getPoolSupply(_pid);

        if (block.number > pool.lastSlopesRewardBlock && lpSupply != 0) {
            uint256 slopesReward = _calculateSlopesReward(_pid, lpSupply);

            // Make sure that slopesReward won't push the total supply of SLOPES past slopes.MAX_SUPPLY()
            uint256 slopesTotalSupply = slopes.totalSupply();
            if (slopesTotalSupply.add(slopesReward) >= slopes.MAX_SUPPLY()) {
                slopesReward = slopes.MAX_SUPPLY().sub(slopesTotalSupply);
            }

            accSlopesPerShare = accSlopesPerShare.add(slopesReward.mul(1e12).div(lpSupply));
        }

        SkiPerks perks = SkiPerks(skiPerksAddress);
        uint256 pendingBoost = perks.skiBoost(nftSkiAddress, _user);

        return user.staked.mul(pendingBoost).div(100).mul(accSlopesPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Get the pending UNIs for a user from 1 pool
    function _pendingUni(uint256 _pid, address _user) internal view returns (uint256) {
        PoolInfo memory pool = poolInfo[_pid];
        UserInfo memory user = userInfo[_pid][_user];
        uint256 accUniPerShare = pool.accUniPerShare;
        uint256 lpSupply = _getPoolSupply(_pid);

        if (pool.uniStakeContract != address(0) && lpSupply != 0) {
            uint256 uniReward = IStakingRewards(pool.uniStakeContract).earned(address(this));
            accUniPerShare = accUniPerShare.add(uniReward.mul(1e12).div(lpSupply));
        }
        return user.staked.mul(accUniPerShare).div(1e12).sub(user.uniRewardDebt);
    }

    // Calculate the current slopesReward for a specific pool
    function _calculateSlopesReward(uint256 _pid, uint256 _lpSupply) internal view returns (uint256 slopesReward) {

        if (slopes.maxSupplyHit() != true) {

            PoolInfo memory pool = poolInfo[_pid];

            uint256 multiplier = block.number - pool.lastSlopesRewardBlock;

            // There will be a 2000 block Soft Launch where SLOPES is minted at a static rate to make things as fair as possible
            if (block.number < startBlock + SOFT_LAUNCH_DURATION) {

                // The SLOPES-ETH pool isn't active until the Uniswap pool is created, which can't happen until at least 500 blocks have passed. Once active, it mints 1000 SLOPES per block (the same amount of SLOPES per block as all of the other pools combined) until the Soft Launch ends
                if (_pid != 0) {
                    // For the first 2000 blocks, give 20 SLOPES per block to all other pools that have staked LP tokens
                    slopesReward = multiplier * SOFT_LAUNCH_SLOPES_PER_BLOCK;
                } else if (slopesPoolActive == true) {
                    slopesReward = multiplier * 25 * SOFT_LAUNCH_SLOPES_PER_BLOCK;
                }

            } else if (_pid != 0 && slopesPoolActive != true) {
                // Keep minting 20 tokens per block since the Soft Launch is over but the SLOPES-ETH pool still isn't active (would only be due to no one calling the activateSlopesPool function)
                slopesReward = multiplier * SOFT_LAUNCH_SLOPES_PER_BLOCK;
            } else if (slopesPoolActive == true) {
                // Afterwards, give slopesReward based on the pool's fixed APR.
                // Fast low gas cost way of calculating prices since this can be called every block.
                uint256 slopesPrice = _getSlopesPrice();
                uint256 lpTokenPrice = 10**18 * 2 * weth.balanceOf(address(pool.lpToken)) / pool.lpToken.totalSupply();
                uint256 scaledTotalLiquidityValue = _lpSupply * lpTokenPrice;
                slopesReward = multiplier * ((pool.apr * scaledTotalLiquidityValue / slopesPrice) / APPROX_BLOCKS_PER_YEAR) / 100;
            }

        }

    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Internal view function to get all of the stored data for a single pool
    function _getPoolData(uint256 _pid) internal view returns (address, address, bool, uint256, uint256, uint256, uint256) {
        PoolInfo memory pool = poolInfo[_pid];
        return (address(pool.token), address(pool.lpToken), pool.uniStakeContract != address(0), pool.apr, pool.lastSlopesRewardBlock, pool.accSlopesPerShare, pool.accUniPerShare);
    }

    // View function to see all of the stored data for every pool on the frontend
    function _getAllPoolData() internal view returns (address[] memory, address[] memory, bool[] memory, uint[] memory, uint[] memory, uint[2][] memory) {
        uint256 length = poolInfo.length;
        address[] memory tokenData = new address[](length);
        address[] memory lpTokenData = new address[](length);
        bool[] memory isUniData = new bool[](length);
        uint[] memory aprData = new uint[](length);
        uint[] memory lastSlopesRewardBlockData = new uint[](length);
        uint[2][] memory accTokensPerShareData = new uint[2][](length);

        for (uint256 pid = 0; pid < length; ++pid) {
            (tokenData[pid], lpTokenData[pid], isUniData[pid], aprData[pid], lastSlopesRewardBlockData[pid], accTokensPerShareData[pid][0], accTokensPerShareData[pid][1]) = _getPoolData(pid);
        }

        return (tokenData, lpTokenData, isUniData, aprData, lastSlopesRewardBlockData, accTokensPerShareData);
    }

    // Internal view function to get all of the extra data for a single pool
    function _getPoolMetadataFor(uint256 _pid, address _user, uint256 _slopesPrice) internal view returns (uint[17] memory poolMetadata) {
        PoolInfo memory pool = poolInfo[_pid];

        uint256 totalSupply;
        uint256 totalLPSupply;
        uint256 stakedLPSupply;
        uint256 tokenPrice;
        uint256 lpTokenPrice;
        uint256 totalLiquidityValue;
        uint256 slopesPerBlock;

        if (_pid != 0 || slopesPoolActive == true) {
            totalSupply = pool.token.totalSupply();
            totalLPSupply = pool.lpToken.totalSupply();
            stakedLPSupply = _getPoolSupply(_pid);

            tokenPrice = 10**uint256(pool.token.decimals()) * weth.balanceOf(address(pool.lpToken)) / pool.token.balanceOf(address(pool.lpToken));
            lpTokenPrice = 10**18 * 2 * weth.balanceOf(address(pool.lpToken)) / totalLPSupply;
            totalLiquidityValue = stakedLPSupply * lpTokenPrice / 1e18;
        }

        // Only calculate with fixed apr after the Soft Launch
        if (block.number >= startBlock + SOFT_LAUNCH_DURATION) {
            slopesPerBlock = ((pool.apr * 1e18 * totalLiquidityValue / _slopesPrice) / APPROX_BLOCKS_PER_YEAR) / 100;
        } else {
            if (_pid != 0) {
                slopesPerBlock = SOFT_LAUNCH_SLOPES_PER_BLOCK;
            } else if (slopesPoolActive == true) {
                slopesPerBlock = 25 * SOFT_LAUNCH_SLOPES_PER_BLOCK;
            }
        }

        // Global pool information
        poolMetadata[0] = totalSupply;
        poolMetadata[1] = totalLPSupply;
        poolMetadata[2] = stakedLPSupply;
        poolMetadata[3] = tokenPrice;
        poolMetadata[4] = lpTokenPrice;
        poolMetadata[5] = totalLiquidityValue;
        poolMetadata[6] = slopesPerBlock;
        poolMetadata[7] = pool.token.decimals();

        // User pool information
        if (_pid != 0 || slopesPoolActive == true) {
            UserInfo memory _userInfo = userInfo[_pid][_user];
            poolMetadata[8] = pool.token.balanceOf(_user);
            poolMetadata[9] = pool.token.allowance(_user, address(this));
            poolMetadata[10] = pool.lpToken.balanceOf(_user);
            poolMetadata[11] = pool.lpToken.allowance(_user, address(this));
            poolMetadata[12] = _userInfo.staked;
            poolMetadata[13] = _pendingSlopes(_pid, _user);
            poolMetadata[14] = _pendingUni(_pid, _user);
            poolMetadata[15] = _userInfo.claimed;
            poolMetadata[16] = _userInfo.uniClaimed;
        }
    }

    // View function to see all of the extra pool data (token prices, total staked supply, total liquidity value, etc) on the frontend
    function _getAllPoolMetadataFor(address _user) internal view returns (uint[17][] memory allMetadata) {
        uint256 length = poolInfo.length;

        // Extra data for the frontend
        allMetadata = new uint[17][](length);

        // We'll need the current SLOPES price to make our calculations
        uint256 slopesPrice = _getSlopesPrice();

        for (uint256 pid = 0; pid < length; ++pid) {
            allMetadata[pid] = _getPoolMetadataFor(pid, _user, slopesPrice);
        }
    }

    // View function to see all of the data for all pools on the frontend
    function getAllPoolInfoFor(address _user) external view returns (address[] memory tokens, address[] memory lpTokens, bool[] memory isUnis, uint[] memory aprs, uint[] memory lastSlopesRewardBlocks, uint[2][] memory accTokensPerShares, uint[17][] memory metadatas) {
        (tokens, lpTokens, isUnis, aprs, lastSlopesRewardBlocks, accTokensPerShares) = _getAllPoolData();
        metadatas = _getAllPoolMetadataFor(_user);
    }

    // Internal view function to get the current price of SLOPES on Uniswap
    function _getSlopesPrice() internal view returns (uint256 slopesPrice) {
        uint256 slopesBalance = slopes.balanceOf(slopesPoolAddress);
        if (slopesBalance > 0) {
            slopesPrice = 10**18 * weth.balanceOf(slopesPoolAddress) / slopesBalance;
        }
    }

    // View function to show all relevant platform info on the frontend
    function getAllInfoFor(address _user) external view returns (bool poolActive, uint256[8] memory info) {
        poolActive = slopesPoolActive;
        info[0] = blocksUntilLaunch();
        info[1] = blocksUntilSlopesPoolCanBeActivated();
        info[2] = blocksUntilSoftLaunchEnds();
        info[3] = slopes.totalSupply();
        info[4] = _getSlopesPrice();
        if (slopesPoolActive) {
            info[5] = IERC20(slopesPoolAddress).balanceOf(address(slopes));
        }
        info[6] = slopesSentToEverest;
        info[7] = slopes.balanceOf(_user);
    }

    // View function to see the number of blocks remaining until launch on the frontend
    function blocksUntilLaunch() public view returns (uint256) {
        if (block.number >= startBlock) return 0;
        else return startBlock.sub(block.number);
    }

    // View function to see the number of blocks remaining until the SLOPES pool can be activated on the frontend
    function blocksUntilSlopesPoolCanBeActivated() public view returns (uint256) {
        uint256 slopesPoolActivationBlock = startBlock + SOFT_LAUNCH_DURATION.div(2);
        if (block.number >= slopesPoolActivationBlock) return 0;
        else return slopesPoolActivationBlock.sub(block.number);
    }

    // View function to see the number of blocks remaining until the Soft Launch ends on the frontend
    function blocksUntilSoftLaunchEnds() public view returns (uint256) {
        uint256 softLaunchEndBlock = startBlock + SOFT_LAUNCH_DURATION;
        if (block.number >= softLaunchEndBlock) return 0;
        else return softLaunchEndBlock.sub(block.number);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = (slopesPoolActive == true ? 0 : 1); pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        require(msg.sender == tx.origin || msg.sender == owner() || contractWhitelist[msg.sender] == true, "no contracts"); // Prevent flash loan attacks that manipulate prices.

        PoolInfo storage pool = poolInfo[_pid];
        uint256 lpSupply = _getPoolSupply(_pid);

        // Handle the UNI staking rewards contract for the LP token if one exists.
        // The SLOPES-ETH pool would break by using the UNI staking rewards contract if one is made for it so it will be ignored
        if (_pid != 0) {
            // Check to see if the LP token has a UNI staking rewards contract to forward deposits to so that users can earn both SLOPES and UNI
            if (pool.uniStakeContract == address(0)) {
                (address uniStakeContract,) = uniStakingFactory.stakingRewardsInfoByStakingToken(address(pool.lpToken));

                // If a UNI staking rewards contract exists then transfer all of the LP tokens to it to start earning UNI
                if (uniStakeContract != address(0)) {
                    pool.uniStakeContract = uniStakeContract;

                    if (lpSupply > 0) {
                        pool.lpToken.safeApprove(uniStakeContract, 0);
                        pool.lpToken.approve(uniStakeContract, lpSupply);
                        IStakingRewards(pool.uniStakeContract).stake(lpSupply);
                    }
                }
            }

            // A UNI staking rewards contract for this LP token is being used so get any pending UNI rewards
            if (pool.uniStakeContract != address(0)) {
                uint256 pendingUniTokens = IStakingRewards(pool.uniStakeContract).earned(address(this));
                if (pendingUniTokens > 0) {
                    uint256 uniBalanceBefore = uniToken.balanceOf(address(this));
                    IStakingRewards(pool.uniStakeContract).getReward();
                    uint256 uniBalanceAfter = uniToken.balanceOf(address(this));
                    pendingUniTokens = uniBalanceAfter.sub(uniBalanceBefore);
                    pool.accUniPerShare = pool.accUniPerShare.add(pendingUniTokens.mul(1e12).div(lpSupply));
                }
            }
        }

        // Only update the pool if the max SLOPES supply hasn't been hit
        if (slopes.maxSupplyHit() != true) {

            if ((block.number <= pool.lastSlopesRewardBlock) || (_pid == 0 && slopesPoolActive != true)) {
                return;
            }
            if (lpSupply == 0) {
                pool.lastSlopesRewardBlock = block.number;
                return;
            }

            uint256 slopesReward = _calculateSlopesReward(_pid, lpSupply);

            // Make sure that slopesReward won't push the total supply of SLOPES past slopes.MAX_SUPPLY()
            uint256 slopesTotalSupply = slopes.totalSupply();
            if (slopesTotalSupply.add(slopesReward) >= slopes.MAX_SUPPLY()) {
                slopesReward = slopes.MAX_SUPPLY().sub(slopesTotalSupply);
            }

            // slopes.mint(devAddress, slopesReward.div(10)); Not minting 10% to the devs like Sushi, Sashimi, and Takeout do

            if (slopesReward > 0) {
                slopes.mint(address(this), slopesReward);
                pool.accSlopesPerShare = pool.accSlopesPerShare.add(slopesReward.mul(1e12).div(lpSupply));
                pool.lastSlopesRewardBlock = block.number;
            }

            if (slopes.maxSupplyHit() == true) {
                everest.activate();
            }
        }
    }

    // Internal view function to get the amount of LP tokens staked in the specified pool
    function _getPoolSupply(uint256 _pid) internal view returns (uint256 lpSupply) {
        PoolInfo memory pool = poolInfo[_pid];

        if (pool.uniStakeContract != address(0)) {
            lpSupply = IStakingRewards(pool.uniStakeContract).balanceOf(address(this));
        } else {
            lpSupply = pool.lpToken.balanceOf(address(this));
        }
    }

    // Deposits LP tokens in the specified pool to start earning the user SLOPES
    function deposit(uint256 _pid, uint256 _amount) external {
        depositFor(_pid, msg.sender, _amount);
    }

    // Deposits LP tokens in the specified pool on behalf of another user
    function depositFor(uint256 _pid, address _user, uint256 _amount) public {
        require(msg.sender == tx.origin || contractWhitelist[msg.sender] == true, "no contracts");
        require(slopes.maxSupplyHit() != true, "pools closed");
        require(_pid != 0 || slopesPoolActive == true, "slopes pool not active");
        require(_amount > 0, "deposit something");

        updatePool(_pid);

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        // The sender needs to give approval to the Yeti contract for the specified amount of the LP token first
        pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);

        // Claim any pending SLOPES and UNI
        _claimRewardsFromPool(_pid, _user);

        // Each pool has a 10% staking fee. If staking in the SLOPES-ETH pool, 100% of the fee gets permanently locked in the SLOPES contract (gives SLOPES liquidity forever).
        // If staking in any other pool, 50% of the fee is used to buyback SLOPES which is sent to the Everest staking contract where it will start getting distributed to stakers after the max supply is hit, and 50% goes to the team.
        // The team is never minted or rewarded SLOPES for any reason to keep things as fair as possible.
        uint256 stakingFeeAmount = _amount.div(10);
        uint256 remainingUserAmount = _amount.sub(stakingFeeAmount);

        // If a UNI staking rewards contract is available, use it
        if (pool.uniStakeContract != address(0)) {
            pool.lpToken.safeApprove(pool.uniStakeContract, 0);
            pool.lpToken.approve(pool.uniStakeContract, remainingUserAmount);
            IStakingRewards(pool.uniStakeContract).stake(remainingUserAmount);
        }

        // The user is depositing to the SLOPES-ETH pool so permanently lock all of the LP tokens from the staking fee in the SLOPES contract
        if (_pid == 0) {
            pool.lpToken.transfer(address(slopes), stakingFeeAmount);
        } else {
            // Remove the liquidity from the pool
            uint256 deadline = block.timestamp + 5 minutes;
            pool.lpToken.approve(address(uniswapRouter), stakingFeeAmount);
            uniswapRouter.removeLiquidityETHSupportingFeeOnTransferTokens(address(pool.token), stakingFeeAmount, 0, 0, address(this), deadline);

            // Swap the ERC-20 token for ETH
            uint256 ethBalanceBeforeSwap = address(this).balance;

            uint256 tokensToSwap = pool.token.balanceOf(address(this));
            require(tokensToSwap > 0, "bad token swap");
            address[] memory poolPath = new address[](2);
            poolPath[0] = address(pool.token);
            poolPath[1] = address(weth);
            pool.token.approve(address(uniswapRouter), tokensToSwap);
            uniswapRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(tokensToSwap, 0, poolPath, address(this), deadline);

            uint256 ethBalanceAfterSwap = address(this).balance;
            uint256 ethReceivedFromStakingFee;
            uint256 teamFeeAmount;

            // If slopesPoolActive == true then perform a buyback of SLOPES using all of the ETH in the contract and then send it to the Everest staking contract. Otherwise, the ETH will be used to seed the initial liquidity in the SLOPES-ETH Uniswap pool when activateSlopesPool is called
            if (slopesPoolActive == true) {
                require(ethBalanceAfterSwap > 0, "bad eth swap");

                teamFeeAmount = ethBalanceAfterSwap.div(2);
                ethReceivedFromStakingFee = ethBalanceAfterSwap.sub(teamFeeAmount);

                // The SLOPES-ETH pool is active, so let's use the ETH to buyback SLOPES and send it to the Everest staking contract
                uint256 slopesBought = _buySlopes(ethReceivedFromStakingFee);

                // Send the SLOPES rewards to the Everest staking contract
                slopesSentToEverest += slopesBought;
                _safeSlopesTransfer(address(everest), slopesBought);
            } else {
                ethReceivedFromStakingFee = ethBalanceAfterSwap.sub(ethBalanceBeforeSwap);
                require(ethReceivedFromStakingFee > 0, "bad eth swap");

                teamFeeAmount = ethReceivedFromStakingFee.div(2);
            }

            if (teamFeeAmount > 0) devAddress.transfer(teamFeeAmount);
        }

        // Add the remaining amount to the user's staked balance
        uint256 _currentRewardDebt = 0;
        uint256 _currentUniRewardDebt = 0;
        if (slopesPoolActive != true) {
            _currentRewardDebt = user.staked.mul(pool.accSlopesPerShare).div(1e12).sub(user.rewardDebt);
            _currentUniRewardDebt = user.staked.mul(pool.accUniPerShare).div(1e12).sub(user.uniRewardDebt);
        }
        user.staked = user.staked.add(remainingUserAmount);
        user.rewardDebt = user.staked.mul(pool.accSlopesPerShare).div(1e12).sub(_currentRewardDebt);
        user.uniRewardDebt = user.staked.mul(pool.accUniPerShare).div(1e12).sub(_currentUniRewardDebt);

        emit Deposit(_user, _pid, _amount);
    }

    // Internal function that buys back SLOPES with the amount of ETH specified
    function _buySlopes(uint256 _amount) internal returns (uint256 slopesBought) {
        uint256 ethBalance = address(this).balance;
        if (_amount > ethBalance) _amount = ethBalance;
        if (_amount > 0) {
            uint256 deadline = block.timestamp + 5 minutes;
            address[] memory slopesPath = new address[](2);
            slopesPath[0] = address(weth);
            slopesPath[1] = address(slopes);
            uint256[] memory amounts = uniswapRouter.swapExactETHForTokens{value: _amount}(0, slopesPath, address(this), deadline);
            slopesBought = amounts[1];
        }
        if (slopesBought > 0) emit SlopesBuyback(msg.sender, _amount, slopesBought);
    }

    // Internal function to claim earned SLOPES and UNI from Yeti. Claiming won't work until slopesPoolActive == true
    function _claimRewardsFromPool(uint256 _pid, address _user) internal {
        PoolInfo memory pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        if (slopesPoolActive != true || user.staked == 0) return;

        uint256 userUniPending = user.staked.mul(pool.accUniPerShare).div(1e12).sub(user.uniRewardDebt);
        uint256 uniBalance = uniToken.balanceOf(address(this));
        if (userUniPending > uniBalance) userUniPending = uniBalance;
        if (userUniPending > 0) {
            user.uniClaimed += userUniPending;
            uniToken.transfer(_user, userUniPending);
        }

        // SKISECURE: boost yield for Ski NFT owners

        SkiPerks perks = SkiPerks(skiPerksAddress);
        uint256 pendingBoost = perks.skiBoost(nftSkiAddress, _user);
        uint256 userSlopesPending = user.staked.mul(pendingBoost).div(100).mul(pool.accSlopesPerShare).div(1e12).sub(user.rewardDebt);
        if (userSlopesPending > 0) {
            user.claimed += userSlopesPending;
            _safeSlopesTransfer(_user, userSlopesPending);
        }

        if (userSlopesPending > 0 || userUniPending > 0) {
            emit Claim(_user, _pid, userSlopesPending, userUniPending);
        }
    }

    // Claim all earned SLOPES and UNI from a single pool. Claiming won't work until slopesPoolActive == true
    function claim(uint256 _pid) public {
        require(slopesPoolActive == true, "slopes pool not active");
        updatePool(_pid);
        _claimRewardsFromPool(_pid, msg.sender);
        UserInfo storage user = userInfo[_pid][msg.sender];
        PoolInfo memory pool = poolInfo[_pid];
        user.rewardDebt = user.staked.mul(pool.accSlopesPerShare).div(1e12);
        user.uniRewardDebt = user.staked.mul(pool.accUniPerShare).div(1e12);
    }

    // Claim all earned SLOPES and UNI from all pools. Claiming won't work until slopesPoolActive == true
    function claimAll() public {
        require(slopesPoolActive == true, "slopes pool not active");

        uint256 totalPendingSlopesAmount = 0;
        uint256 totalPendingUniAmount = 0;

        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            UserInfo storage user = userInfo[pid][msg.sender];

            if (user.staked > 0) {
                updatePool(pid);

                PoolInfo storage pool = poolInfo[pid];
                uint256 accSlopesPerShare = pool.accSlopesPerShare;
                uint256 accUniPerShare = pool.accUniPerShare;

                uint256 pendingPoolSlopesRewards = user.staked.mul(accSlopesPerShare).div(1e12).sub(user.rewardDebt);
                user.claimed += pendingPoolSlopesRewards;
                totalPendingSlopesAmount = totalPendingSlopesAmount.add(pendingPoolSlopesRewards);
                user.rewardDebt = user.staked.mul(accSlopesPerShare).div(1e12);

                uint256 pendingPoolUniRewards = user.staked.mul(accUniPerShare).div(1e12).sub(user.uniRewardDebt);
                user.uniClaimed += pendingPoolUniRewards;
                totalPendingUniAmount = totalPendingUniAmount.add(pendingPoolUniRewards);
                user.uniRewardDebt = user.staked.mul(accUniPerShare).div(1e12);
            }
        }

        require(totalPendingSlopesAmount > 0 || totalPendingUniAmount > 0, "nothing to claim");

        uint256 uniBalance = uniToken.balanceOf(address(this));
        if (totalPendingUniAmount > uniBalance) totalPendingUniAmount = uniBalance;
        if (totalPendingUniAmount > 0) uniToken.transfer(msg.sender, totalPendingUniAmount);

        if (totalPendingSlopesAmount > 0) _safeSlopesTransfer(msg.sender, totalPendingSlopesAmount);

        emit ClaimAll(msg.sender, totalPendingSlopesAmount, totalPendingUniAmount);
    }

    // Withdraw LP tokens and earned SLOPES from Yeti. Withdrawing won't work until slopesPoolActive == true
    function withdraw(uint256 _pid, uint256 _amount) public {
        require(slopesPoolActive == true, "slopes pool not active");
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(_amount > 0 && user.staked >= _amount, "withdraw: not good");

        updatePool(_pid);

        // Claim any pending SLOPES and UNI
        _claimRewardsFromPool(_pid, msg.sender);

        PoolInfo memory pool = poolInfo[_pid];

        // If a UNI staking rewards contract is in use, withdraw from it
        if (pool.uniStakeContract != address(0)) {
            IStakingRewards(pool.uniStakeContract).withdraw(_amount);
        }

        user.staked = user.staked.sub(_amount);
        user.rewardDebt = user.staked.mul(pool.accSlopesPerShare).div(1e12);
        user.uniRewardDebt = user.staked.mul(pool.accUniPerShare).div(1e12);

        pool.lpToken.safeTransfer(address(msg.sender), _amount);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Convenience function to allow users to migrate all of their staked SLOPES-ETH LP tokens from Yeti to the Everest staking contract after the max supply is hit. Migrating won't work until everest.active() == true
    function migrateSLOPESLPtoEverest() public {
        require(everest.active() == true, "everest not active");
        UserInfo storage user = userInfo[0][msg.sender];
        uint256 amountToMigrate = user.staked;
        require(amountToMigrate > 0, "migrate: not good");

        updatePool(0);

        // Claim any pending SLOPES
        _claimRewardsFromPool(0, msg.sender);

        user.staked = 0;
        user.rewardDebt = 0;

        poolInfo[0].lpToken.approve(address(everest), amountToMigrate);
        everest.stakeFor(msg.sender, amountToMigrate);
        emit Withdraw(msg.sender, 0, amountToMigrate);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 staked = user.staked;
        require(staked > 0, "no tokens");

        PoolInfo memory pool = poolInfo[_pid];

        // If a UNI staking rewards contract is in use, withdraw from it
        if (pool.uniStakeContract != address(0)) {
            IStakingRewards(pool.uniStakeContract).withdraw(staked);
        }

        user.staked = 0;
        user.rewardDebt = 0;
        user.uniRewardDebt = 0;

        pool.lpToken.safeTransfer(address(msg.sender), staked);
        emit EmergencyWithdraw(msg.sender, _pid, staked);
    }

    // Internal function to safely transfer SLOPES in case there is a rounding error
    function _safeSlopesTransfer(address _to, uint256 _amount) internal {
        uint256 slopesBalance = slopes.balanceOf(address(this));
        if (_amount > slopesBalance) _amount = slopesBalance;
        slopes.transfer(_to, _amount);
    }

    // Creates the SLOPES-ETH Uniswap pool and adds the initial liqudity that will be permanently locked. Can be called by anyone, but no sooner than 500 blocks after launch.
    function activateSlopesPool() public {
        require(slopesPoolActive == false, "already active");
        require(block.number > startBlock + SOFT_LAUNCH_DURATION.div(2), "too soon");
        uint256 initialEthLiquidity = address(this).balance;
        require(initialEthLiquidity > 0, "need ETH");

        massUpdatePools();

        // The ETH raised from the staking fees collected before slopesPoolActive == true is used to seed the ETH side of the SLOPES-ETH Uniswap pool.
        // This means that the higher the staking volume during the first 500 blocks, the higher the initial price of SLOPES
        if (donatedETH > 0 && donatedETH < initialEthLiquidity) initialEthLiquidity = initialEthLiquidity.sub(donatedETH);

        // Mint 1,000,000 new SLOPES to seed the SLOPES liquidity in the SLOPES-ETH Uniswap pool
        uint256 initialSlopesLiquidity = 1000000 * 10**18;
        slopes.mint(address(this), initialSlopesLiquidity);

        // Add the liquidity to the SLOPES-ETH Uniswap pool
        slopes.approve(address(uniswapRouter), initialSlopesLiquidity);
        ( , , uint256 lpTokensReceived) = uniswapRouter.addLiquidityETH{value: initialEthLiquidity}(address(slopes), initialSlopesLiquidity, 0, 0, address(this), block.timestamp + 5 minutes);

        // Activate the SLOPES-ETH pool
        initialSlopesPoolETH = initialEthLiquidity;
        slopesPoolActive = true;

        // Permanently lock the LP tokens in the SLOPES contract
        IERC20(slopesPoolAddress).transfer(address(slopes), lpTokensReceived);

        // Buy SLOPES with all of the donatedETH from partner projects. This SLOPES will be sent to the Everest staking contract and will start getting distributed to all stakers when the max supply is hit
        uint256 donatedAmount = donatedETH;
        uint256 ethBalance = address(this).balance;
        if (donatedAmount > ethBalance) donatedAmount = ethBalance;
        if (donatedAmount > 0) {
            uint256 slopesBought = _buySlopes(donatedAmount);

            // Send the SLOPES rewards to the Everest staking contract
            slopesSentToEverest += slopesBought;
            _safeSlopesTransfer(address(everest), slopesBought);
            donatedETH = 0;
        }

        emit SlopesPoolActive(msg.sender, initialSlopesLiquidity, initialEthLiquidity);
    }

    // For use by partner teams that are donating to the SLOPES community. The funds will be used to purchase SLOPES tokens which will be distributed to stakers once the max supply is hit
    function donate(address _lpToken) public payable {
        require(msg.value >= minimumDonationAmount);
        require(donaters[_lpToken] == address(0));

        donatedETH = donatedETH.add(msg.value);
        donaters[_lpToken] = msg.sender;
        donations[_lpToken] = msg.value;
    }

    // For use by partner teams that donated to the SLOPES community. The funds can be removed if a beach wasn't created for the specified lp token (meaning the SLOPES team didn't hold up their end of the agreement)
    function removeDonation(address _lpToken) public {
        require(block.number < startBlock); // Donations can only be removed if the beach hasn't been added by the startBlock

        address returnAddress = donaters[_lpToken];
        require(msg.sender == returnAddress);

        uint256 donationAmount = donations[_lpToken];
        require(donationAmount > 0);

        uint256 ethBalance = address(this).balance;
        require(donationAmount <= ethBalance);

        // Only refund the donation if the beach wasn't created
        require(existingPools[_lpToken] != true);

        donatedETH = donatedETH.sub(donationAmount);
        donaters[_lpToken] = address(0);
        donations[_lpToken] = 0;

        msg.sender.transfer(donationAmount);
    }

    //////////////////////////
    // Governance Functions //
    //////////////////////////
    // The following functions can only be called by the owner
    // (the SLOPES token holder governance contract)

    // SKISECURE: setup period for 1 hour when onlyOwner function ignores timelocks
    uint setupPeriod = block.timestamp + 3600;


    // SKISECURE: candidate system for each onlyOwner function, no unexpected changes
    address everestContractCandidate;
    uint everestContractStamp;
    //
    uint addPoolStamp;
    address[] addPoolCandidate;
    //
    uint[] setAprCandidate;
    uint setAprStamp;
    //
    address whitelistCandidate;
    uint whitelistStamp;
    //
    address blacklistCandidate;
    uint blacklistStamp;

    // Sets the address of the Everest staking contract that bought SLOPES gets sent to for distribution to stakers once the max supply is hit
    function setEverestContract(Everest _everest) public onlyOwner {
        // SKISECURE: pass argument if still in setup period
        if (setupPeriod > now ) {
            everest = _everest;
        } else {
        // SKISECURE: enact candidate if timelock expired
            if (everestContractStamp > now && everestContractStamp != 0) {
                everest = everestContractCandidate;
                everestContractStamp = 0;
                // SKISECURE: set up candidate, launch timelock
                } else {
                everestContractCandidate = _everest;
                everestContractStamp = now + 86400;
            }
        }
    }

    // Add a new LP Token pool
    function addPool(address _token, address _lpToken, uint256 _apr, bool _requireDonation) public onlyOwner {
        require(slopes.maxSupplyHit() != true);
        require(existingPools[_lpToken] != true, "pool exists");
        require(_requireDonation != true || donations[_lpToken] >= minimumDonationAmount, "must donate");
        // SKISECURE: pass argument if still in setup period
        if (setupPeriod > now) {
            _addPool(_token, _lpToken);
            if (_apr != DEFAULT_APR) poolInfo[poolInfo.length-1].apr = _apr;
        } else {
        // SKISECURE: enact candidate if timelock expired
            if (addPoolStamp > now && addPoolStamp != 0) {
                _addPool(addPoolCandidate[0], addPoolCandidate[1]);
                if (_apr != DEFAULT_APR) poolInfo[poolInfo.length-1].apr = _apr;
                addPoolStamp = 0;
                // SKISECURE: set up candidate, launch timelock
            } else {
                addPoolCandidate[0] = _token;
                addPoolCandidate[1] = _lpToken;
                addPoolStamp = now + 86400;
            }
        }
    }

    // Update the given pool's APR
    function setApr(uint256 _pid, uint256 _apr) public onlyOwner {
        require(slopes.maxSupplyHit() != true);
        // SKISECURE: pass argument if still in setup period
        if (setupPeriod > now) {
            updatePool(_pid);
            poolInfo[_pid].apr = _apr;
        } else {
        // SKISECURE: enact candidate if timelock expired
            if (setAprStamp > now && setAprStamp != 0) {
                updatePool(setAprCandidate[0]);
                poolInfo[setAprCandidate[0]].apr = setAprCandidate[1];
                setAprStamp = 0;
                // SKISECURE: set up candidate, launch timelock
            } else {
                setAprCandidate[0] = _pid;
                setAprCandidate[1] = _apr;
                // SKISECURE: apr has a reduced timelock, 10 minutes
                setAprStamp = now + 600;
            }
        }
    }

    // Add a contract to the whitelist so that it can interact with Yeti.
    // This is needed for the Aegis pool contract to be able to stake on behalf of
    // everyone in the pool.
    // We want limited interaction from contracts due to the growing "flash loan"
    // trend that can be used to dramatically manipulate a token's price in a single block.
    function addToWhitelist(address _contractAddress) public onlyOwner {
        // SKISECURE: pass argument if still in setup period
        if (setupPeriod > now) {
            contractWhitelist[_contractAddress] = true;
        } else {
        // SKISECURE: enact candidate if timelock expired
            if (whitelistStamp > now && whitelistStamp != 0) {
                contractWhitelist[whitelistCandidate] = true;
                whitelistStamp = 0;
                // SKISECURE: set up candidate, launch timelock
            } else {
                whitelistCandidate = _contractAddress;
                whitelistStamp = now + 86400;
            }
        }
    }

    // Remove a contract from the whitelist
    function removeFromWhitelist(address _contractAddress) public onlyOwner {
        // SKISECURE: pass argument if still in setup period
        if (setupPeriod > now) {
            contractWhitelist[_contractAddress] = false;
        } else {
        // SKISECURE: enact candidate if timelock expired
            if (blacklistStamp > now && blacklistStamp != 0) {
                contractWhitelist[blacklistCandidate] = false;
                blacklistStamp = 0;
                // SKISECURE: set up candidate, launch timelock
            } else {
                blacklistCandidate = _contractAddress;
                blacklistStamp = now + 86400;
            }
        }
    }

}
