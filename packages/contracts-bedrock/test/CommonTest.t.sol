// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

// Testing utilities
import { Test, StdUtils } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { L2OutputOracle } from "src/L1/L2OutputOracle.sol";
import { L2ToL1MessagePasser } from "src/L2/L2ToL1MessagePasser.sol";
import { L1StandardBridge } from "src/L1/L1StandardBridge.sol";
import { L2StandardBridge } from "src/L2/L2StandardBridge.sol";
import { StandardBridge } from "src/universal/StandardBridge.sol";
import { L1ERC721Bridge } from "src/L1/L1ERC721Bridge.sol";
import { L2ERC721Bridge } from "src/L2/L2ERC721Bridge.sol";
import { OptimismMintableERC20Factory } from "src/universal/OptimismMintableERC20Factory.sol";
import { OptimismMintableERC721Factory } from "src/universal/OptimismMintableERC721Factory.sol";
import { OptimismMintableERC20 } from "src/universal/OptimismMintableERC20.sol";
import { OptimismPortal } from "src/L1/OptimismPortal.sol";
import { L1CrossDomainMessenger } from "src/L1/L1CrossDomainMessenger.sol";
import { L2CrossDomainMessenger } from "src/L2/L2CrossDomainMessenger.sol";
import { SequencerFeeVault } from "src/L2/SequencerFeeVault.sol";
import { FeeVault } from "src/universal/FeeVault.sol";
import { AddressAliasHelper } from "src/vendor/AddressAliasHelper.sol";
import { LegacyERC20ETH } from "src/legacy/LegacyERC20ETH.sol";
import { Predeploys } from "src/libraries/Predeploys.sol";
import { Types } from "src/libraries/Types.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Proxy } from "src/universal/Proxy.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ResolvedDelegateProxy } from "src/legacy/ResolvedDelegateProxy.sol";
import { AddressManager } from "src/legacy/AddressManager.sol";
import { L1ChugSplashProxy } from "src/legacy/L1ChugSplashProxy.sol";
import { IL1ChugSplashDeployer } from "src/legacy/L1ChugSplashProxy.sol";
import { CrossDomainMessenger } from "src/universal/CrossDomainMessenger.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { LegacyMintableERC20 } from "src/legacy/LegacyMintableERC20.sol";
import { SystemConfig } from "src/L1/SystemConfig.sol";
import { ResourceMetering } from "src/L1/ResourceMetering.sol";
import { Constants } from "src/libraries/Constants.sol";
import { FFIInterface } from "test/setup/FFIInterface.sol";

contract CommonTest is Test {
    address alice = address(128);
    address bob = address(256);
    address multisig = address(512);

    address immutable ZERO_ADDRESS = address(0);
    address immutable NON_ZERO_ADDRESS = address(1);
    uint256 immutable NON_ZERO_VALUE = 100;
    uint256 immutable ZERO_VALUE = 0;
    uint64 immutable NON_ZERO_GASLIMIT = 50000;
    bytes32 nonZeroHash = keccak256(abi.encode("NON_ZERO"));
    bytes NON_ZERO_DATA = hex"0000111122223333444455556666777788889999aaaabbbbccccddddeeeeffff0000";

    event TransactionDeposited(address indexed from, address indexed to, uint256 indexed version, bytes opaqueData);

    /// @dev OpenZeppelin Ownable.sol transferOwnership event
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    FFIInterface ffi;

    function setUp() public virtual {
        // Give alice and bob some ETH
        vm.deal(alice, 1 << 16);
        vm.deal(bob, 1 << 16);
        vm.deal(multisig, 1 << 16);

        vm.label(alice, "alice");
        vm.label(bob, "bob");
        vm.label(multisig, "multisig");

        // Make sure we have a non-zero base fee
        vm.fee(1000000000);

        ffi = new FFIInterface();
    }

    function emitTransactionDeposited(
        address _from,
        address _to,
        uint256 _mint,
        uint256 _value,
        uint64 _gasLimit,
        bool _isCreation,
        bytes memory _data
    )
        internal
    {
        emit TransactionDeposited(_from, _to, 0, abi.encodePacked(_mint, _value, _gasLimit, _isCreation, _data));
    }
}

contract L2OutputOracle_Initializer is CommonTest {
    // Test target
    L2OutputOracle oracle;
    L2OutputOracle oracleImpl;

    L2ToL1MessagePasser messagePasser = L2ToL1MessagePasser(payable(Predeploys.L2_TO_L1_MESSAGE_PASSER));

    // Constructor arguments
    address internal proposer = 0x000000000000000000000000000000000000AbBa;
    address internal owner = 0x000000000000000000000000000000000000ACDC;
    uint256 internal submissionInterval = 1800;
    uint256 internal l2BlockTime = 2;
    uint256 internal startingBlockNumber = 200;
    uint256 internal startingTimestamp = 1000;
    uint256 internal finalizationPeriodSeconds = 7 days;
    address guardian;

    // Test data
    uint256 initL1Time;

    event OutputProposed(
        bytes32 indexed outputRoot, uint256 indexed l2OutputIndex, uint256 indexed l2BlockNumber, uint256 l1Timestamp
    );

    event OutputsDeleted(uint256 indexed prevNextOutputIndex, uint256 indexed newNextOutputIndex);

    // Advance the evm's time to meet the L2OutputOracle's requirements for proposeL2Output
    function warpToProposeTime(uint256 _nextBlockNumber) public {
        vm.warp(oracle.computeL2Timestamp(_nextBlockNumber) + 1);
    }

    /// @dev Helper function to propose an output.
    function proposeAnotherOutput() public {
        bytes32 proposedOutput2 = keccak256(abi.encode());
        uint256 nextBlockNumber = oracle.nextBlockNumber();
        uint256 nextOutputIndex = oracle.nextOutputIndex();
        warpToProposeTime(nextBlockNumber);
        uint256 proposedNumber = oracle.latestBlockNumber();

        // Ensure the submissionInterval is enforced
        assertEq(nextBlockNumber, proposedNumber + submissionInterval);

        vm.roll(nextBlockNumber + 1);

        vm.expectEmit(true, true, true, true);
        emit OutputProposed(proposedOutput2, nextOutputIndex, nextBlockNumber, block.timestamp);

        vm.prank(proposer);
        oracle.proposeL2Output(proposedOutput2, nextBlockNumber, 0, 0);
    }

    function setUp() public virtual override {
        super.setUp();
        guardian = makeAddr("guardian");

        // By default the first block has timestamp and number zero, which will cause underflows in the
        // tests, so we'll move forward to these block values.
        initL1Time = startingTimestamp + 1;
        vm.warp(initL1Time);
        vm.roll(startingBlockNumber);
        // Deploy the L2OutputOracle and transfer owernship to the proposer
        oracleImpl = new L2OutputOracle({
            _submissionInterval: submissionInterval,
            _l2BlockTime: l2BlockTime,
            _finalizationPeriodSeconds: finalizationPeriodSeconds
        });
        Proxy proxy = new Proxy(multisig);
        vm.prank(multisig);
        proxy.upgradeToAndCall(
            address(oracleImpl),
            abi.encodeCall(L2OutputOracle.initialize, (startingBlockNumber, startingTimestamp, proposer, owner))
        );
        oracle = L2OutputOracle(address(proxy));
        vm.label(address(oracle), "L2OutputOracle");

        // Set the L2ToL1MessagePasser at the correct address
        vm.etch(Predeploys.L2_TO_L1_MESSAGE_PASSER, address(new L2ToL1MessagePasser()).code);

        vm.label(Predeploys.L2_TO_L1_MESSAGE_PASSER, "L2ToL1MessagePasser");
    }
}

contract Portal_Initializer is L2OutputOracle_Initializer {
    // Test target
    OptimismPortal internal opImpl;
    OptimismPortal internal op;
    SystemConfig systemConfig;

    event WithdrawalFinalized(bytes32 indexed withdrawalHash, bool success);
    event WithdrawalProven(bytes32 indexed withdrawalHash, address indexed from, address indexed to);

    function setUp() public virtual override {
        super.setUp();

        Proxy systemConfigProxy = new Proxy(multisig);

        SystemConfig systemConfigImpl = new SystemConfig();

        vm.prank(multisig);
        systemConfigProxy.upgradeToAndCall(
            address(systemConfigImpl),
            abi.encodeCall(
                SystemConfig.initialize,
                (
                    address(1), //_owner,
                    0, //_overhead,
                    10000, //_scalar,
                    bytes32(0), //_batcherHash,
                    30_000_000, //_gasLimit,
                    address(0), //_unsafeBlockSigner,
                    Constants.DEFAULT_RESOURCE_CONFIG(), //_config,
                    0, //_startBlock
                    address(0xff), // _batchInbox
                    SystemConfig.Addresses({ // _addresses
                        l1CrossDomainMessenger: address(0),
                        l1ERC721Bridge: address(0),
                        l1StandardBridge: address(0),
                        l2OutputOracle: address(oracle),
                        optimismPortal: address(op),
                        optimismMintableERC20Factory: address(0)
                    })
                )
            )
        );

        systemConfig = SystemConfig(address(systemConfigProxy));

        opImpl = new OptimismPortal();

        Proxy proxy = new Proxy(multisig);
        vm.prank(multisig);
        proxy.upgradeToAndCall(
            address(opImpl), abi.encodeCall(OptimismPortal.initialize, (oracle, guardian, systemConfig, false))
        );
        op = OptimismPortal(payable(address(proxy)));
        vm.label(address(op), "OptimismPortal");
    }
}

contract Messenger_Initializer is Portal_Initializer {
    AddressManager internal addressManager;
    L1CrossDomainMessenger internal L1Messenger;
    L2CrossDomainMessenger internal L2Messenger = L2CrossDomainMessenger(Predeploys.L2_CROSS_DOMAIN_MESSENGER);

    event SentMessage(address indexed target, address sender, bytes message, uint256 messageNonce, uint256 gasLimit);

    event SentMessageExtension1(address indexed sender, uint256 value);

    event MessagePassed(
        uint256 indexed nonce,
        address indexed sender,
        address indexed target,
        uint256 value,
        uint256 gasLimit,
        bytes data,
        bytes32 withdrawalHash
    );

    event RelayedMessage(bytes32 indexed msgHash);
    event FailedRelayedMessage(bytes32 indexed msgHash);

    event TransactionDeposited(
        address indexed from,
        address indexed to,
        uint256 mint,
        uint256 value,
        uint64 gasLimit,
        bool isCreation,
        bytes data
    );

    event WhatHappened(bool success, bytes returndata);

    function setUp() public virtual override {
        super.setUp();

        // Deploy the address manager
        vm.prank(multisig);
        addressManager = new AddressManager();

        // Setup implementation
        L1CrossDomainMessenger L1MessengerImpl = new L1CrossDomainMessenger();

        // Setup the address manager and proxy
        vm.prank(multisig);
        addressManager.setAddress("OVM_L1CrossDomainMessenger", address(L1MessengerImpl));
        ResolvedDelegateProxy proxy = new ResolvedDelegateProxy(
            addressManager,
            "OVM_L1CrossDomainMessenger"
        );
        L1Messenger = L1CrossDomainMessenger(address(proxy));
        L1Messenger.initialize(op);

        vm.etch(Predeploys.L2_CROSS_DOMAIN_MESSENGER, address(new L2CrossDomainMessenger(address(L1Messenger))).code);

        L2Messenger.initialize();

        // Label addresses
        vm.label(address(addressManager), "AddressManager");
        vm.label(address(L1MessengerImpl), "L1CrossDomainMessenger_Impl");
        vm.label(address(L1Messenger), "L1CrossDomainMessenger_Proxy");
        vm.label(Predeploys.LEGACY_ERC20_ETH, "LegacyERC20ETH");
        vm.label(Predeploys.L2_CROSS_DOMAIN_MESSENGER, "L2CrossDomainMessenger");

        vm.label(AddressAliasHelper.applyL1ToL2Alias(address(L1Messenger)), "L1CrossDomainMessenger_aliased");
    }
}

contract Bridge_Initializer is Messenger_Initializer {
    L1StandardBridge L1Bridge;
    L2StandardBridge L2Bridge;
    OptimismMintableERC20Factory L2TokenFactory;
    OptimismMintableERC20Factory L1TokenFactory;
    ERC20 L1Token;
    ERC20 BadL1Token;
    OptimismMintableERC20 L2Token;
    LegacyMintableERC20 LegacyL2Token;
    ERC20 NativeL2Token;
    ERC20 BadL2Token;
    OptimismMintableERC20 RemoteL1Token;

    event ETHDepositInitiated(address indexed from, address indexed to, uint256 amount, bytes data);

    event ETHWithdrawalFinalized(address indexed from, address indexed to, uint256 amount, bytes data);

    event ERC20DepositInitiated(
        address indexed l1Token, address indexed l2Token, address indexed from, address to, uint256 amount, bytes data
    );

    event ERC20WithdrawalFinalized(
        address indexed l1Token, address indexed l2Token, address indexed from, address to, uint256 amount, bytes data
    );

    event WithdrawalInitiated(
        address indexed l1Token, address indexed l2Token, address indexed from, address to, uint256 amount, bytes data
    );

    event DepositFinalized(
        address indexed l1Token, address indexed l2Token, address indexed from, address to, uint256 amount, bytes data
    );

    event DepositFailed(
        address indexed l1Token, address indexed l2Token, address indexed from, address to, uint256 amount, bytes data
    );

    event ETHBridgeInitiated(address indexed from, address indexed to, uint256 amount, bytes data);

    event ETHBridgeFinalized(address indexed from, address indexed to, uint256 amount, bytes data);

    event ERC20BridgeInitiated(
        address indexed localToken,
        address indexed remoteToken,
        address indexed from,
        address to,
        uint256 amount,
        bytes data
    );

    event ERC20BridgeFinalized(
        address indexed localToken,
        address indexed remoteToken,
        address indexed from,
        address to,
        uint256 amount,
        bytes data
    );

    function setUp() public virtual override {
        super.setUp();

        vm.label(Predeploys.L2_STANDARD_BRIDGE, "L2StandardBridge");
        vm.label(Predeploys.OPTIMISM_MINTABLE_ERC20_FACTORY, "OptimismMintableERC20Factory");

        // Deploy the L1 bridge and initialize it with the address of the
        // L1CrossDomainMessenger
        L1ChugSplashProxy proxy = new L1ChugSplashProxy(multisig);
        vm.mockCall(multisig, abi.encodeWithSelector(IL1ChugSplashDeployer.isUpgrading.selector), abi.encode(true));
        vm.startPrank(multisig);
        proxy.setCode(address(new L1StandardBridge()).code);
        vm.clearMockedCalls();
        address L1Bridge_Impl = proxy.getImplementation();
        vm.stopPrank();

        L1Bridge = L1StandardBridge(payable(address(proxy)));
        L1Bridge.initialize({ _messenger: L1Messenger });

        vm.label(address(proxy), "L1StandardBridge_Proxy");
        vm.label(address(L1Bridge_Impl), "L1StandardBridge_Impl");

        // Deploy the L2StandardBridge, move it to the correct predeploy
        // address and then initialize it. It is safe to call initialize directly
        // on the proxy because the bytecode was set in state with `etch`.
        vm.etch(Predeploys.L2_STANDARD_BRIDGE, address(new L2StandardBridge(StandardBridge(payable(proxy)))).code);
        L2Bridge = L2StandardBridge(payable(Predeploys.L2_STANDARD_BRIDGE));
        L2Bridge.initialize();

        // Set up the L2 mintable token factory
        OptimismMintableERC20Factory factory = new OptimismMintableERC20Factory();
        vm.etch(Predeploys.OPTIMISM_MINTABLE_ERC20_FACTORY, address(factory).code);
        L2TokenFactory = OptimismMintableERC20Factory(Predeploys.OPTIMISM_MINTABLE_ERC20_FACTORY);
        L2TokenFactory.initialize(Predeploys.L2_STANDARD_BRIDGE);

        vm.etch(Predeploys.LEGACY_ERC20_ETH, address(new LegacyERC20ETH()).code);

        L1Token = new ERC20("Native L1 Token", "L1T");

        LegacyL2Token = new LegacyMintableERC20({
            _l2Bridge: address(L2Bridge),
            _l1Token: address(L1Token),
            _name: string.concat("LegacyL2-", L1Token.name()),
            _symbol: string.concat("LegacyL2-", L1Token.symbol())
        });
        vm.label(address(LegacyL2Token), "LegacyMintableERC20");

        // Deploy the L2 ERC20 now
        L2Token = OptimismMintableERC20(
            L2TokenFactory.createStandardL2Token(
                address(L1Token),
                string(abi.encodePacked("L2-", L1Token.name())),
                string(abi.encodePacked("L2-", L1Token.symbol()))
            )
        );

        BadL2Token = OptimismMintableERC20(
            L2TokenFactory.createStandardL2Token(
                address(1),
                string(abi.encodePacked("L2-", L1Token.name())),
                string(abi.encodePacked("L2-", L1Token.symbol()))
            )
        );

        NativeL2Token = new ERC20("Native L2 Token", "L2T");
        Proxy factoryProxy = new Proxy(multisig);
        OptimismMintableERC20Factory L1TokenFactoryImpl = new OptimismMintableERC20Factory();

        vm.prank(multisig);
        factoryProxy.upgradeToAndCall(
            address(L1TokenFactoryImpl), abi.encodeCall(OptimismMintableERC20Factory.initialize, address(L1Bridge))
        );

        L1TokenFactory = OptimismMintableERC20Factory(address(factoryProxy));

        RemoteL1Token = OptimismMintableERC20(
            L1TokenFactory.createStandardL2Token(
                address(NativeL2Token),
                string(abi.encodePacked("L1-", NativeL2Token.name())),
                string(abi.encodePacked("L1-", NativeL2Token.symbol()))
            )
        );

        BadL1Token = OptimismMintableERC20(
            L1TokenFactory.createStandardL2Token(
                address(1),
                string(abi.encodePacked("L1-", NativeL2Token.name())),
                string(abi.encodePacked("L1-", NativeL2Token.symbol()))
            )
        );
    }
}

contract ERC721Bridge_Initializer is Bridge_Initializer {
    L1ERC721Bridge L1NFTBridge;
    L2ERC721Bridge L2NFTBridge;

    function setUp() public virtual override {
        super.setUp();

        // Deploy the L1ERC721Bridge.
        L1ERC721Bridge l1BridgeImpl = new L1ERC721Bridge();
        Proxy l1BridgeProxy = new Proxy(multisig);

        vm.prank(multisig);
        l1BridgeProxy.upgradeToAndCall(
            address(l1BridgeImpl), abi.encodeCall(L1ERC721Bridge.initialize, (CrossDomainMessenger(L1Messenger)))
        );

        L1NFTBridge = L1ERC721Bridge(address(l1BridgeProxy));

        // Deploy the implementation for the L2ERC721Bridge and etch it into the predeploy address.
        L2ERC721Bridge l2BridgeImpl = new L2ERC721Bridge(address(L1NFTBridge));
        Proxy l2BridgeProxy = new Proxy(multisig);
        vm.etch(Predeploys.L2_ERC721_BRIDGE, address(l2BridgeProxy).code);

        // set the storage slot for admin
        bytes32 OWNER_KEY = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
        vm.store(Predeploys.L2_ERC721_BRIDGE, OWNER_KEY, bytes32(uint256(uint160(multisig))));

        vm.prank(multisig);
        Proxy(payable(Predeploys.L2_ERC721_BRIDGE)).upgradeToAndCall(
            address(l2BridgeImpl), abi.encodeCall(L2ERC721Bridge.initialize, ())
        );

        // Set up a reference to the L2ERC721Bridge.
        L2NFTBridge = L2ERC721Bridge(Predeploys.L2_ERC721_BRIDGE);

        // Label the L1 and L2 bridges.
        vm.label(address(L1NFTBridge), "L1ERC721Bridge");
        vm.label(address(L2NFTBridge), "L2ERC721Bridge");
    }
}

contract FeeVault_Initializer is Bridge_Initializer {
    SequencerFeeVault vault = SequencerFeeVault(payable(Predeploys.SEQUENCER_FEE_WALLET));
    address constant recipient = address(1024);

    event Withdrawal(uint256 value, address to, address from);

    event Withdrawal(uint256 value, address to, address from, FeeVault.WithdrawalNetwork withdrawalNetwork);
}
