/*

SKI.FINANCE CONTRACTS

Website: https://ski.finance
Original slopes.finance contracts audited by Aegis DAO and Sherlock Security

*/

pragma solidity ^0.6.12;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

contract GameItems is ERC1155 {
    uint256 public constant ALIEN = 0;
    uint256 public constant ZOMBIE = 1;
    uint256 public constant CHEF = 2;
    uint256 public constant CYBERPUNK= 3;
    uint256 public constant SURFER = 4;
    uint256 public constant COWBOY = 5;
    uint256 public constant SANTA = 6;
    uint256 public constant LINKY = 7;
    uint256 public constant HEXER = 8;

    constructor() public ERC1155("https://ski.finance/skis/{1}.json") {
        _mint(msg.sender, ALIEN, 3, "");
        _mint(msg.sender, ZOMBIE, 10, "");
        _mint(msg.sender, CHEF, 15, "");
        _mint(msg.sender, CYBERPUNK, 20, "");
        _mint(msg.sender, SURFER, 25, "");
        _mint(msg.sender, COWBOY, 25, "");
        _mint(msg.sender, SANTA, 25, "");
        _mint(msg.sender, LINKY, 25, "");
        _mint(msg.sender, HEXER, 25, "");
    }
}
