pragma solidity ^0.6.12;

import './IUniswapV2Router02.sol';
import './IUniswapV2Pair.sol';
import './SafeERC20.sol';
import './IERC20.sol';
import './Yeti.sol';
import './Everest.sol';

contract AutoDeposit {
    using SafeERC20 for IERC20;

    IUniswapV2Router02 internal uniswapRouter = IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    Yeti internal yeti;
    Everest internal everest;

    constructor(Yeti _yeti, Everest _everest) public {
        yeti = _yeti;
        everest = _everest;
    }

    receive() external payable {
        require(msg.sender != tx.origin);
    }

    function depositInto(uint256 _pid) external payable returns (uint256 lpReceived) {
        require(msg.value > 0 && _pid < yeti.poolLength());

        (IERC20 _token, IERC20 _pool, , , , , ) = yeti.poolInfo(_pid);

        lpReceived = _convertToLP(_token, _pool, msg.value);
        _pool.safeApprove(address(yeti), 0);
        _pool.safeApprove(address(yeti), lpReceived);
        yeti.depositFor(_pid, msg.sender, lpReceived);
    }

    function giveFor(uint256 _pid) external payable returns (uint256 lpReceived) {
        require(msg.value > 0 && _pid < yeti.poolLength());

        (IERC20 _token, IERC20 _pool, , , , , ) = yeti.poolInfo(_pid);

        lpReceived = _convertToLP(_token, _pool, msg.value);
        _pool.transfer(msg.sender, lpReceived);
    }

    function stake() external payable returns (uint256 lpReceived) {
        require(msg.value > 0 && everest.active());

        lpReceived = _convertToLP(IERC20(everest.slopes()), everest.slopesPool(), msg.value);
        everest.slopesPool().safeApprove(address(everest), 0);
        everest.slopesPool().safeApprove(address(everest), lpReceived);
        everest.stakeFor(msg.sender, lpReceived);
    }


    function _convertToLP(IERC20 _token, IERC20 _pool, uint256 _amount) internal returns (uint256) {
        require(_amount > 0);

        address[] memory _poolPath = new address[](2);
        _poolPath[0] = uniswapRouter.WETH();
        _poolPath[1] = address(_token);
        uniswapRouter.swapExactETHForTokens{value: _amount / 2}(0, _poolPath, address(this), block.timestamp + 5 minutes);

        return _addLP(_token, _pool, _token.balanceOf(address(this)), address(this).balance);
    }

    function _addLP(IERC20 _token, IERC20 _pool, uint256 _tokens, uint256 _eth) internal returns (uint256 liquidityAdded) {
        require(_tokens > 0 && _eth > 0);

        IUniswapV2Pair _pair = IUniswapV2Pair(address(_pool));
        (uint256 _reserve0, uint256 _reserve1, ) = _pair.getReserves();
        bool _isToken0 = _pair.token0() == address(_token);
        uint256 _tokensPerETH = 1e18 * (_isToken0 ? _reserve0 : _reserve1) / (_isToken0 ? _reserve1 : _reserve0);

        _token.safeApprove(address(uniswapRouter), 0);
        if (_tokensPerETH > 1e18 * _tokens / _eth) {
            uint256 _ethValue = 1e18 * _tokens / _tokensPerETH;
            _token.safeApprove(address(uniswapRouter), _tokens);
            ( , , liquidityAdded) = uniswapRouter.addLiquidityETH{value: _ethValue}(address(_token), _tokens, 0, 0, address(this), block.timestamp + 5 minutes);
        } else {
            uint256 _tokenValue = 1e18 * _tokensPerETH / _eth;
            _token.safeApprove(address(uniswapRouter), _tokenValue);
            ( , , liquidityAdded) = uniswapRouter.addLiquidityETH{value: _eth}(address(_token), _tokenValue, 0, 0, address(this), block.timestamp + 5 minutes);
        }

        uint256 _remainingETH = address(this).balance;
        uint256 _remainingTokens = _token.balanceOf(address(this));
        if (_remainingETH > 0) {
            msg.sender.transfer(_remainingETH);
        }
        if (_remainingTokens > 0) {
            _token.transfer(msg.sender, _remainingTokens);
        }
    }
}
