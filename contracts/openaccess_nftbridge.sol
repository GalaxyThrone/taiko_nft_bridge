// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

interface ITaikoBridgeContract {
    function sendSignal(bytes32 signal) external returns (bytes32 storageSlot);

    function getSignalSlot(
        address app,
        bytes32 signal
    ) external returns (bytes32);

    function isSignalReceived(
        uint256 srcChainId,
        address app,
        bytes32 signal,
        bytes calldata proof
    ) external returns (bool);
}

// Abstract contract, add appropriate functionality later
abstract contract WrappedNFT {
    function claimBridged(
        uint256 srcChainId,
        address app,
        bytes32 signal,
        bytes calldata proof
    ) public virtual returns (bool, address, address, uint);

    function addSisterContract(
        address _newSisterContractOnOtherChain
    ) public virtual;
}

// Contract for open access NFT bridge [WIP]

// deploys wrapped nft contracts on the other chain
contract openAccessNFTBridge is Ownable, IERC721Receiver {
    using Counters for Counters.Counter;

    ITaikoBridgeContract taikoBridge;

    // Use different starting points for each chain to prevent overlap
    Counters.Counter private _tokenIdCounter;

    // Define bridge and chain contracts and IDs
    address public taikoBridgeContract =
        address(0x0000777700000000000000000000000000000007); // SignalService Taiko

    address public sepoliaBridgeContract =
        address(0x11013a48Ad87a528D23CdA25D2C34D7dbDA6b46b); // SignalService Sepolia

    uint public sepoliaChainId = 11155111; //ChainID Sepolia

    uint public taikoChainId = 167002; //ChainID Taiko A2

    uint public currentChainType = 0; // 1 for L1, 2 for L2

    address public currentBridgeSignalContract;

    // The bridge contract on the other side. Actually useless atm.
    address public currentSisterContract;

    bool sisterBridgeSetup = false;

    uint public currentChainId;

    uint public currentSisterChainId;

    struct TokenInformation {
        uint originNetwork;
        address originTokenAddress;
    }

    // Wrapped token Address --> Origin token information
    mapping(address => TokenInformation) public wrappedTokenToTokenInfo;

    event bridgeRequestSent(
        address owner,
        address indexednftContract,
        uint indexed nftId
    );

    // Constructor function for the contract
    constructor(uint _chainType) {
        currentChainType = _chainType;

        if (_chainType == 1) {
            currentBridgeSignalContract = sepoliaBridgeContract;

            currentChainId = sepoliaChainId;
            currentSisterChainId = taikoChainId;
        }

        if (_chainType == 2) {
            currentBridgeSignalContract = taikoBridgeContract;

            currentChainId = taikoChainId;
            currentSisterChainId = sepoliaChainId;
        }
    }

    // Mapping to store NFTs being held
    mapping(address => mapping(uint => bool)) heldNFT;

    mapping(address => address) public sisterContract;

    // Add a new sister contract
    function addSisterContract(address _newSisterContract) external {
        sisterContract[msg.sender] = _newSisterContract;
    }

    // Add a sister contract via signature
    function addSisterContractViaSignature(
        address _newSisterContract,
        bytes memory _signature
    ) external {
        // TODO
        // for non-upgradable NFT Contracts to be L2 Bridge compliant
    }

    function addSisterBridgeContract(
        address _SisterContractInit
    ) external onlyOwner {
        //sister bridge contract can only be set up once
        //@TODO use create2 to have same contract address on both chains instead.

        require(!sisterBridgeSetup, "can only set up contract once");
        sisterBridgeSetup = true;
        currentSisterContract = _SisterContractInit;
    }

    //requestId => storageSlot;
    mapping(uint => bytes32) public storageSlotsBridgeRequest;

    mapping(uint => address) public bridgeRequestInitiatorUser;

    mapping(uint => address) public bridgeRequestInitiatorSender;

    mapping(uint => bytes32) public sentPayload;
    uint public totalRequestsSent;

    event bridgeData(address indexed sender, bytes32 indexed dataPayload);

    // Bridge NFT to sister chain
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) public override returns (bytes4) {
        address nftContractAddr = msg.sender;

        bytes32 encodedData = encodeMessagePayload(
            nftContractAddr,
            from,
            tokenId
        );

        //@TODO if not supported natively by original NFT Contract, deploy wrapped nftContract on claimBridged.
        storageSlotsBridgeRequest[totalRequestsSent] = pingBridgeForTransfer(
            encodedData
        );

        sentPayload[totalRequestsSent] = encodedData;
        bridgeRequestInitiatorUser[totalRequestsSent] = from;
        bridgeRequestInitiatorSender[totalRequestsSent] = msg.sender;

        totalRequestsSent++;
        heldNFT[nftContractAddr][tokenId] = true;

        emit bridgeRequestSent(from, msg.sender, tokenId);

        return this.onERC721Received.selector;
    }

    // Returns true or false if message received, the original NFT Contract address from the other chain, the owner of the NFT, and the tokenId
    function claimBridged(
        uint256 srcChainId,
        address _origin,
        bytes32 _dataPayload,
        bytes calldata proof
    ) external returns (bool, address, address, uint) {
        require(
            _origin == currentSisterContract,
            "message not from sisterBridgeContract!"
        );

        taikoBridge = ITaikoBridgeContract(currentBridgeSignalContract);

        bool response = taikoBridge.isSignalReceived(
            srcChainId,
            _origin,
            _dataPayload,
            proof
        );

        (
            address _addrOwner,
            address _addrOriginNftContract,
            uint256 _nftId
        ) = decodeMessagePayload(_dataPayload);

        // If we hold the NFT from a previous bridging, we return it to the owner here.
        //@notice this path requires native NFT Contract support.
        //@notice namely, the sisterContract has to be set up.
        if (heldNFT[sisterContract[_addrOriginNftContract]][_nftId]) {
            address sisterContractAddress = sisterContract[
                _addrOriginNftContract
            ];

            require(
                sisterContractAddress != address(0),
                "no sister contract specified!"
            );

            IERC721 sisterNftContract = IERC721(sisterContractAddress);

            sisterNftContract.safeTransferFrom(
                sisterContractAddress,
                _addrOwner,
                _nftId
            );
            //give back empty data.
            return (response, address(0), address(0), 0);
        }
        //@notice deploy wrappedNFT Token
        else {}

        //data to be used for the native NFT Contract Specified Sister.
        return (response, _addrOriginNftContract, _addrOwner, _nftId);
    }

    function pingBridgeForTransfer(
        bytes32 _dataPayload
    ) internal returns (bytes32) {
        emit bridgeData(msg.sender, _dataPayload);
        taikoBridge = ITaikoBridgeContract(currentBridgeSignalContract);

        return taikoBridge.sendSignal(_dataPayload);
    }

    // Encode data payload to bytes32 for cross-chain messaging
    function encodeMessagePayload(
        address _addrOwner,
        address _addrOriginNftContract,
        uint256 _nftId
    ) public pure returns (bytes32) {
        bytes32 encoded = bytes32(
            (uint256(uint160(_addrOwner)) << 96) |
                (uint256(uint160(_addrOriginNftContract)) << 32) |
                _nftId
        );
        return encoded;
    }

    // Decode data payload from bytes32 for cross-chain messaging
    function decodeMessagePayload(
        bytes32 encodedMessageNFTBridge
    ) public pure returns (address, address, uint256) {
        address _addrOwner = address(
            uint160(uint256(encodedMessageNFTBridge) >> 96)
        );
        address _addrOriginNftContract = address(
            uint160((uint256(encodedMessageNFTBridge) << 160) >> 192)
        );
        uint256 _nftId = uint256(encodedMessageNFTBridge) & 0xFFFFFFFF;
        return (_addrOwner, _addrOriginNftContract, _nftId);
    }
}
