// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {DeployRaffle} from "../../script/DeployRaffle.s.sol";
import {Raffle} from "../../src/Raffle.sol";
import {Test, console} from "forge-std/Test.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {Vm} from "forge-std/Vm.sol";
import {VRFCoordinatorV2Mock} from "../../lib/chainlink-brownie-contracts/contracts/src/v0.8/mocks/VRFCoordinatorV2Mock.sol";

contract RaffleTest is Test {
    event EnteredRaffle(address indexed player);
    event WinnerPicked(address indexed winner);

    Raffle raffle;
    HelperConfig config;

    uint256 entranceFee;
    uint256 interval;
    address vrfCoordinator;
    bytes32 keyHash;
    uint64 subscriptionId;
    uint32 callbackGasLimit;
    address link;

    address public PLAYER = makeAddr("player");
    uint256 public constant STARTING_BALANCE = 1000 ether;

    modifier arrange() {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        _;
    }

    function setUp() external {
        DeployRaffle deployer = new DeployRaffle();
        (raffle, config) = deployer.run();
        (
            entranceFee,
            interval,
            vrfCoordinator,
            keyHash,
            subscriptionId,
            callbackGasLimit,
            link
        ) = config.activeNetworkConfig();
        vm.deal(PLAYER, STARTING_BALANCE);
    }

    function testRaffleInitializesInOPENState() public view {
        assert(raffle.getRaffleState() == Raffle.RaffleState.OPEN);
    }

    function testRaffleRevertsOnInsufficientFund() public {
        vm.prank(PLAYER);
        vm.expectRevert(Raffle.Raffle__NotEnoughETHSent.selector);
        raffle.enterRaffle();
    }

    function testRaffleRecordsParticipants() public {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        raffle.getPlayers(0);
        address playerRecorded = raffle.getPlayers(0);
        assert(playerRecorded == PLAYER);
    }

    function testRaffleRevertsEntryIfStateIsNotOPEN() public arrange {
        raffle.performUpkeep("");

        vm.expectRevert(Raffle.Raffle__EntriesClosed.selector);
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
    }

    function testEmitsEventOnEntrance() public {
        vm.expectEmit(true, false, false, false, address(raffle));
        emit EnteredRaffle(PLAYER);
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
    }

    ///////////////////////////////
    //////////checkUpKeep//////////
    ///////////////////////////////
    function testCheckUpKeepReturnsFalseIfItHasNoBalance() public {
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        (bool upkeepNeeded, ) = raffle.checkUpkeep("");
        assert(!upkeepNeeded);
    }

    function testCheckUpKeepReturnsFalseIfRaffleNotOpen() public arrange {
        raffle.performUpkeep("");
        (bool upkeepNeeded, ) = raffle.checkUpkeep("");
        assert(!upkeepNeeded);
    }

    function testCheckUpKeepReturnsFalseIfEnoughTimeHasntPasses() public {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        vm.warp(block.timestamp + interval - 1);
        vm.roll(block.number + 1);
        raffle.performUpkeep("");
        (bool upkeepNeeded, ) = raffle.checkUpkeep("");
        assert(!upkeepNeeded);
    }

    function testCheckUpKeepReturnsTrueWhenParamatersAreGood() public arrange {
        (bool upkeepNeeded, ) = raffle.checkUpkeep("");
        assert(upkeepNeeded);
    }

    ///////////////////////////////
    /////////performUpKeep/////////
    ///////////////////////////////

    function testPerformUpkeepCanOnlyRunIfCheckUpkeepIsTrue() public arrange {
        raffle.performUpkeep("");
    }

    function testPerformUpkeepRevertsIfCheckUpkeepIsFalse() public {
        uint256 currentBalance = 0;
        uint256 numPlayers = 0;
        uint256 state = 0;
        vm.expectRevert(
            abi.encodeWithSelector(
                Raffle.Raffle__UpkeepNotNeeded.selector,
                currentBalance,
                numPlayers,
                state
            )
        );
        raffle.performUpkeep("");
    }

    // event testing //
    function testPerformUpkeepUpdatesRaffleStateAndEmitsRequestId()
        public
        arrange
    {
        vm.recordLogs();
        raffle.performUpkeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];
        Raffle.RaffleState rState = raffle.getRaffleState();
        assert(uint256(requestId) > 0);
        assert(uint256(rState) == 1);
    }

    ///////////////////////////////
    //////fulfillRandomWords///////
    ///////////////////////////////

    function testFulfillRandomWordsCanOnlyBeCalledAfterPerformUpkeep(
        uint256 randomRequestId
    ) public arrange {
        vm.expectRevert("nonexistent request");
        VRFCoordinatorV2Mock(vrfCoordinator).fulfillRandomWords(
            randomRequestId,
            address(raffle)
        );
    }

    function testFulfillRandomWordsPicksAWinnerResetsAndSendsMoney()
        public
        arrange
    {
        uint256 additionalEntrants = 5;
        uint256 startingIndex = 1;
        for (
            uint256 i = startingIndex;
            i < startingIndex + additionalEntrants;
            i++
        ) {
            address player = address(uint160(i));
            hoax(player, STARTING_BALANCE);
            raffle.enterRaffle{value: entranceFee}();
        }

        uint256 prize = entranceFee * (additionalEntrants + 1);

        vm.recordLogs();
        raffle.performUpkeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];

        uint256 previousTimeStamp = raffle.getLastTimeStamp();

        VRFCoordinatorV2Mock(vrfCoordinator).fulfillRandomWords(
            uint256(requestId),
            address(raffle)
        );

        assert(uint256(raffle.getRaffleState()) == 0);
        assert(raffle.getRecentWinner() != address(0));
        assert(raffle.getLengthOfPlayers() == 0);
        assert(previousTimeStamp < raffle.getLastTimeStamp());
        console.log(raffle.getRecentWinner().balance);
        console.log(prize);
        assert(
            raffle.getRecentWinner().balance ==
                prize + STARTING_BALANCE - entranceFee
        );
    }
}
