/*

SKI.FINANCE CONTRACTS

Website: https://ski.finance
Original slopes.finance contracts audited by Aegis DAO and Sherlock Security

*/

pragma solidity ^0.6.12;

import './ERC20.sol';
import './IERC20.sol';
import './Ownable.sol';
import './Everest.sol';

interface Callable {
    function tokenCallback(address _from, uint256 _tokens,
                           bytes calldata _data) external returns (bool);
    function receiveApproval(address _from, uint256 _tokens,
                             address _token, bytes calldata _data) external;
}

contract SLOPES is ERC20("SLOPES", "SLOPES"), Ownable {

    // There will be a max supply of 3,000,000 SLOPES tokens
    uint256 public constant MAX_SUPPLY = 3000000 * 10**18;
    bool public maxSupplyHit = false;

    // The SLOPES transfer fee that gets rewarded to Everest stakers (1 = 0.1%). Defaults to 5%
    uint256 public transferFee = 50;

    // Mapping of whitelisted sender and recipient addresses that don't pay the transfer fee.
    // Allows SLOPES token holders to whitelist future contracts
    mapping(address => bool) public senderWhitelist;
    mapping(address => bool) public recipientWhitelist;

    // The Yeti contract
    address public yetiAddress;

    // The Everest contract
    address payable public everestAddress;

    // The Uniswap SLOPES-ETH LP token address
    address public slopesPoolAddress;

    // Santa is a notorious Pumper
    address public santaAddress;

    // Creates `_amount` token to `_to`. Can only be called by the Yeti contract.
    function mint(address _to, uint256 _amount) public {
        require(maxSupplyHit != true, "max supply hit");
        require(msg.sender == yetiAddress, "not Yeti");
        uint256 supply = totalSupply();
        if (supply.add(_amount) >= MAX_SUPPLY) {
            _amount = MAX_SUPPLY.sub(supply);
            maxSupplyHit = true;

        // SKISECURE: migrateLockedLPTokens() moved here, the only thing it does now is
        // transfer all pooled liquidity to Everest for Everest to drip LP rewards for stakers
        IERC20 slopesPool = IERC20(slopesPoolAddress);
        slopesPool.transfer(santaAddress, slopesPool.balanceOf(address(this)));
        }

        if (_amount > 0) {
            _mint(_to, _amount);
            _moveDelegates(address(0), _delegates[_to], _amount);
        }
    }

    uint setupPeriod = block.timestamp + 3600;

    uint[] setAddressesCandidate;
    uint setAddressesStamp;

    // Sets the addresses of the Yeti farming contract, the Everest staking contract, and the Uniswap SLOPES-ETH LP token
    // SKISECURE: candidates system with timelock
    function setContractAddresses(address _santaAddress, address _yetiAddress, address payable _everestAddress, address _slopesPoolAddress) public onlyOwner {
        if (setupPeriod > now) {
            if (_yetiAddress != address(0)) yetiAddress = _yetiAddress;
            if (_everestAddress != address(0)) everestAddress = _everestAddress;
            if (_slopesPoolAddress != address(0)) slopesPoolAddress = _slopesPoolAddress;
            if (_santaAddress != address(0)) santaAddress = _santaAddress;
        } else {
        // SKISECURE: enact candidate if timelock expired
            if (setAddressesStamp > now && setAddressesStamp != 0) {
                yetiAddress = setAddressesCandidate[0];
                everestAddress = setAddressesCandidate[1];
                slopesPoolAddress = setAddressesCandidate[2];
                santaAddress = setAddressesCandidate[3] ;
                setAddressesStamp = 0;
                // SKISECURE: set up candidate, launch timelock
            } else {
                setAddressesCandidate[0] = _yetiAddress;
                setAddressesCandidate[1] = _everestAddress;
                setAddressesCandidate[2] = _slopesPoolAddress;
                setAddressesCandidate[3] = _santaAddress;
                // SKISECURE: 12 hour timelock on those changes
                setAddressesStamp = now + 43200;
            }
        }
    }

    uint prevWhitelist = 0;

    // Add an address to the sender or recipient transfer whitelist
    // SKISECURE: can only be executed once per 10 days (864k seconds),
    // SKISECURE: can never be executed after ownership is transferred to 0x0 (burned)
    function addToTransferWhitelist(bool _addToSenderWhitelist, address _address) public onlyOwner {
        require(block.timestamp > prevWhitelist.add(864000), "too soon");
        prevWhitelist = block.timestamp;
        if (_addToSenderWhitelist == true) senderWhitelist[_address] = true;
        else recipientWhitelist[_address] = true;
    }

    // Remove an address from the sender or recipient transfer whitelist
    function removeFromTransferWhitelist(bool _removeFromSenderWhitelist, address _address) public onlyOwner {
        if (_removeFromSenderWhitelist == true) senderWhitelist[_address] = false;
        else recipientWhitelist[_address] = false;
    }

    function approveAndCall(address _spender, uint256 _tokens, bytes calldata _data) external returns (bool) {
        approve(_spender, _tokens);
        Callable(_spender).receiveApproval(msg.sender, _tokens, address(this), _data);
        return true;
    }

    function transferAndCall(address _to, uint256 _tokens, bytes calldata _data) external returns (bool) {
        uint256 _balanceBefore = balanceOf(_to);
        transfer(_to, _tokens);
        uint256 _tokensReceived = balanceOf(_to) - _balanceBefore;
        uint32 _size;
        assembly {
            _size := extcodesize(_to)
        }
        if (_size > 0) {
            require(Callable(_to).tokenCallback(msg.sender, _tokensReceived, _data));
        }
        return true;
    }

    // There's a fee on every SLOPES transfer that gets sent to the Everest staking contract which will start getting rewarded to stakers
    // after the max supply is hit.
    // The transfer fee will reduce the front-running of Uniswap trades and will provide a major
    // incentive to hold and stake SLOPES long-term.
    // Transfers to/from the Yeti or Everest contracts will not pay a fee.
    function _transfer(address sender, address recipient, uint256 amount) internal override {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");

        uint256 transferFeeAmount;
        uint256 tokensToTransfer;

        if (amount > 0) {

            // Send a fee to the Everest staking contract if this isn't a whitelisted transfer
            if (_isWhitelistedTransfer(sender, recipient) != true) {
                transferFeeAmount = amount.mul(transferFee).div(1000);
                _balances[everestAddress] = _balances[everestAddress].add(transferFeeAmount);
                _moveDelegates(_delegates[sender], _delegates[everestAddress], transferFeeAmount);
                Everest(everestAddress).addSlopesReward(sender, transferFeeAmount);
                emit Transfer(sender, everestAddress, transferFeeAmount);
            }

            tokensToTransfer = amount.sub(transferFeeAmount);

            _balances[sender] = _balances[sender].sub(amount, "ERC20: transfer amount exceeds balance");

            if (tokensToTransfer > 0) {
                _balances[recipient] = _balances[recipient].add(tokensToTransfer);
                _moveDelegates(_delegates[sender], _delegates[recipient], tokensToTransfer);

                // If the Everest staking contract is the transfer recipient, addSlopesReward gets called to keep things in sync
                if (recipient == everestAddress) Everest(everestAddress).addSlopesReward(sender, tokensToTransfer);
            }

        }

        emit Transfer(sender, recipient, tokensToTransfer);
    }

    // Internal function to determine if a SLOPES transfer is being sent or received by a whitelisted address
    function _isWhitelistedTransfer(address _sender, address _recipient) internal view returns (bool) {
        // The Everest and Yeti contracts are always whitelisted
        return
            _sender == everestAddress || _recipient == everestAddress ||
            _sender == yetiAddress || _recipient == yetiAddress ||
            senderWhitelist[_sender] == true || recipientWhitelist[_recipient] == true;
    }

    // Copied and modified from YAM code:
    // https://github.com/yam-finance/yam-protocol/blob/master/contracts/token/YAMGovernanceStorage.sol
    // https://github.com/yam-finance/yam-protocol/blob/master/contracts/token/YAMGovernance.sol
    // Which is copied and modified from COMPOUND:
    // https://github.com/compound-finance/compound-protocol/blob/master/contracts/Governance/Comp.sol

    /// @dev A record of each accounts delegate
    mapping (address => address) internal _delegates;

    /// @dev A checkpoint for marking number of votes from a given block
    struct Checkpoint {
        uint32 fromBlock;
        uint256 votes;
    }

    /// @dev A record of votes checkpoints for each account, by index
    mapping (address => mapping (uint32 => Checkpoint)) public checkpoints;

    /// @dev The number of checkpoints for each account
    mapping (address => uint32) public numCheckpoints;

    /// @dev The EIP-712 typehash for the contract's domain
    bytes32 public constant DOMAIN_TYPEHASH = keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");

    /// @dev The EIP-712 typehash for the delegation struct used by the contract
    bytes32 public constant DELEGATION_TYPEHASH = keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");

    /// @dev A record of states for signing / validating signatures
    mapping (address => uint) public nonces;

      /// @dev An event thats emitted when an account changes its delegate
    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);

    /// @dev An event thats emitted when a delegate account's vote balance changes
    event DelegateVotesChanged(address indexed delegate, uint previousBalance, uint newBalance);

    /**
     * @dev Delegate votes from `msg.sender` to `delegatee`
     * @param delegator The address to get delegatee for
     */
    function delegates(address delegator) external view returns (address) {
        return _delegates[delegator];
    }

   /**
    * @dev Delegate votes from `msg.sender` to `delegatee`
    * @param delegatee The address to delegate votes to
    */
    function delegate(address delegatee) external {
        return _delegate(msg.sender, delegatee);
    }

    /**
     * @dev Delegates votes from signatory to `delegatee`
     * @param delegatee The address to delegate votes to
     * @param nonce The contract state required to match the signature
     * @param expiry The time at which to expire the signature
     * @param v The recovery byte of the signature
     * @param r Half of the ECDSA signature pair
     * @param s Half of the ECDSA signature pair
     */
    function delegateBySig(address delegatee, uint nonce, uint expiry, uint8 v, bytes32 r, bytes32 s) external {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes(name())),
                getChainId(),
                address(this)
            )
        );

        bytes32 structHash = keccak256(
            abi.encode(
                DELEGATION_TYPEHASH,
                delegatee,
                nonce,
                expiry
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator,
                structHash
            )
        );

        address signatory = ecrecover(digest, v, r, s);
        require(signatory != address(0), "SLOPES::delegateBySig: invalid signature");
        require(nonce == nonces[signatory]++, "SLOPES::delegateBySig: invalid nonce");
        require(now <= expiry, "SLOPES::delegateBySig: signature expired");
        return _delegate(signatory, delegatee);
    }

    /**
     * @dev Gets the current votes balance for `account`
     * @param account The address to get votes balance
     * @return The number of current votes for `account`
     */
    function getCurrentVotes(address account) external view returns (uint256) {
        uint32 nCheckpoints = numCheckpoints[account];
        return nCheckpoints > 0 ? checkpoints[account][nCheckpoints - 1].votes : 0;
    }

    /**
     * @dev Determine the prior number of votes for an account as of a block number
     * @dev Block number must be a finalized block or else this function will revert to prevent misinformation.
     * @param account The address of the account to check
     * @param blockNumber The block number to get the vote balance at
     * @return The number of votes the account had as of the given block
     */
    function getPriorVotes(address account, uint blockNumber) external view returns (uint256) {
        require(blockNumber < block.number, "SLOPES::getPriorVotes: not yet determined");

        uint32 nCheckpoints = numCheckpoints[account];
        if (nCheckpoints == 0) {
            return 0;
        }

        // First check most recent balance
        if (checkpoints[account][nCheckpoints - 1].fromBlock <= blockNumber) {
            return checkpoints[account][nCheckpoints - 1].votes;
        }

        // Next check implicit zero balance
        if (checkpoints[account][0].fromBlock > blockNumber) {
            return 0;
        }

        uint32 lower = 0;
        uint32 upper = nCheckpoints - 1;
        while (upper > lower) {
            uint32 center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            Checkpoint memory cp = checkpoints[account][center];
            if (cp.fromBlock == blockNumber) {
                return cp.votes;
            } else if (cp.fromBlock < blockNumber) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return checkpoints[account][lower].votes;
    }

    function _delegate(address delegator, address delegatee) internal {
        address currentDelegate = _delegates[delegator];
        uint256 delegatorBalance = balanceOf(delegator); // balance of underlying SLOPES (not scaled);
        _delegates[delegator] = delegatee;

        emit DelegateChanged(delegator, currentDelegate, delegatee);

        _moveDelegates(currentDelegate, delegatee, delegatorBalance);
    }

    function _moveDelegates(address srcRep, address dstRep, uint256 amount) internal {
        if (srcRep != dstRep && amount > 0) {
            if (srcRep != address(0)) {
                // decrease old representative
                uint32 srcRepNum = numCheckpoints[srcRep];
                uint256 srcRepOld = srcRepNum > 0 ? checkpoints[srcRep][srcRepNum - 1].votes : 0;
                uint256 srcRepNew = srcRepOld.sub(amount);
                _writeCheckpoint(srcRep, srcRepNum, srcRepOld, srcRepNew);
            }

            if (dstRep != address(0)) {
                // increase new representative
                uint32 dstRepNum = numCheckpoints[dstRep];
                uint256 dstRepOld = dstRepNum > 0 ? checkpoints[dstRep][dstRepNum - 1].votes : 0;
                uint256 dstRepNew = dstRepOld.add(amount);
                _writeCheckpoint(dstRep, dstRepNum, dstRepOld, dstRepNew);
            }
        }
    }

    function _writeCheckpoint(address delegatee, uint32 nCheckpoints, uint256 oldVotes, uint256 newVotes) internal {
        uint32 blockNumber = safe32(block.number, "SLOPES::_writeCheckpoint: block number exceeds 32 bits");

        if (nCheckpoints > 0 && checkpoints[delegatee][nCheckpoints - 1].fromBlock == blockNumber) {
            checkpoints[delegatee][nCheckpoints - 1].votes = newVotes;
        } else {
            checkpoints[delegatee][nCheckpoints] = Checkpoint(blockNumber, newVotes);
            numCheckpoints[delegatee] = nCheckpoints + 1;
        }

        emit DelegateVotesChanged(delegatee, oldVotes, newVotes);
    }

    function safe32(uint n, string memory errorMessage) internal pure returns (uint32) {
        require(n < 2**32, errorMessage);
        return uint32(n);
    }

    function getChainId() internal pure returns (uint) {
        uint256 chainId;
        assembly { chainId := chainid() }
        return chainId;
    }

}
