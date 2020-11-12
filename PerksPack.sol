/*


SKI.FINANCE CONTRACTS

Website: https://ski.finance
Original slopes.finance contracts audited by Aegis DAO and Sherlock Security

*/

// SKISECURE: calculate perks for owning SKI NFTs

pragma solidity ^0.6.12;

import './IERC1155.sol';

contract PerksPack {

    // SKISECURE: boost yields for Ski NFT owners
    function skiBoost(address nftSkiAddress, address _who) public view returns (uint256) {
        IERC1155 skis = IERC1155(nftSkiAddress);
        uint256 boost = (90 * skis.balanceOf(_who, 1) +
                         60 * skis.balanceOf(_who, 1) +
                         50 * skis.balanceOf(_who, 1) +
                         40 * skis.balanceOf(_who, 1) +
                         25 * skis.balanceOf(_who, 1) +
                         20 * skis.balanceOf(_who, 1) +
                         18 * skis.balanceOf(_who, 1) +
                         15 * skis.balanceOf(_who, 1)) + 100;
        if (boost > 350) boost = 350;
        return boost;
    }

    // SKISECURE: staking perks
    function everestPerks(address nftSkiAddress, address _who) public view returns (uint256) {
        return 100;
    }

    // SKISECURE: placeholder for future perks
    function fancyPerks(address nftSkiAddress, address _who) public view returns (uint256) {
        return 100;
    }
}
