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
import './IERC1155.sol';
import './SLOPES.sol';
import './Yeti.sol';


contract Santa is Ownable {

    // The SLOPES-ETH Uniswap LP token
    IERC20 public slopesPool;
    // The SLOPES TOKEN!
    SLOPES public slopes;
    // The Yeti contract
    Yeti public yeti;
    // The Uniswap v2 Router
    IUniswapV2Router02 public uniswapRouter = IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    // WETH
    IERC20 public weth;

    constructor(SLOPES _slopes, Yeti _yeti) public {
        yeti = _yeti;
        slopes = _slopes;
        slopesPool = IERC20(yeti.slopesPoolAddress());
        weth = IERC20(uniswapRouter.WETH());
    }

    function pumpPrice(uint256 _amount, uint256 _lpTokensToConvertToSlopes) public onlyOwner {
        slopesPool.approve(address(uniswapRouter), _lpTokensToConvertToSlopes);
        uniswapRouter.removeLiquidityETHSupportingFeeOnTransferTokens(address(slopes), _lpTokensToConvertToSlopes, 0, 0, address(this), block.timestamp + 5 minutes);
        _buySlopes(_amount);
    }

    // Internal function to buy back SLOPES with the amount of ETH specified
    function _buySlopes(uint256 _amount) internal {
        uint256 deadline = block.timestamp + 5 minutes;
        address[] memory slopesPath = new address[](2);
        slopesPath[0] = address(uniswapRouter.WETH());
        slopesPath[1] = address(slopes);
        uniswapRouter.swapExactETHForTokens{value: _amount}(0, slopesPath, address(this), deadline);
    }

}
