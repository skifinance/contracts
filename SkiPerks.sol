/*


SKI.FINANCE CONTRACTS

Website: https://ski.finance
Original slopes.finance contracts audited by Aegis DAO and Sherlock Security

*/

// SKISECURE: calculate perks for owning SKI NFTs

pragma solidity ^0.6.12;

import './Ownable.sol';
import './IERC1155.sol';
import './PerksPack.sol';

contract SkiPerks is Ownable {

    // SKISECURE: perksPack is a contract packing NFT perks, can be migrated with 24 hour timelock via candidate system
    address perksPackAddress;

    // SKISECURE: candidate system for each onlyOwner function, no unexpected changes
    address perksPackCandidate;
    uint perksPackStamp;

    // SKISECURE: setup period for 1 hour when onlyOwner function ignores timelocks
    uint setupPeriod = block.timestamp + 3600;

    function skiBoost(address _nftSkiAddress, address _who) public view returns (uint256) {
        PerksPack pack = PerksPack(perksPackAddress);
        return pack.skiBoost(_nftSkiAddress, _who);
    }

    // SKISECURE: staking perks
    function everestPerks(address _nftSkiAddress, address _who) public view returns (uint256) {
        PerksPack pack = PerksPack(perksPackAddress);
        return pack.everestPerks(_nftSkiAddress, _who);
    }

    // SKISECURE: placeholder for future perks
    function fancyPerks(address _nftSkiAddress, address _who) public view returns (uint256) {
        PerksPack pack = PerksPack(perksPackAddress);
        return pack.fancyPerks(_nftSkiAddress, _who);
    }

    // Sets the address of the perksPack contract
    function setPackAddress(address _packAddress) public onlyOwner {
        // SKISECURE: pass argument if still in setup period
        if (setupPeriod > now ) {
            perksPackAddress = _packAddress;
        } else {
        // SKISECURE: enact candidate if timelock expired
            if (perksPackStamp > now && perksPackStamp != 0) {
                perksPackAddress = perksPackCandidate;
                perksPackStamp = 0;
                // SKISECURE: set up candidate, launch timelock
                } else {
                perksPackCandidate = _packAddress;
                perksPackStamp = now + 86400;
            }
        }
    }
}
