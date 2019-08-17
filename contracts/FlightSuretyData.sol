pragma solidity ^0.5.8;

import "../node_modules/openzeppelin-solidity/contracts/math/SafeMath.sol";


contract FlightSuretyData {

    using SafeMath for uint256;

    /********************************************************************************************/
    /*                                       DATA VARIABLES                                     */
    /********************************************************************************************/

    address private contractOwner;                                                      // Account used to deploy contract
    bool private operational = true;                                                    // Blocks all state changes throughout the contract if false
    uint256 private entrancyCounter;                                                    // Re-entrancy counter to prevent re-entrancy attack
    uint256 private totalAirlines;                                                      // total of actived airline

    mapping(address => uint256) private airlineFund;                                    // Fund submit by airline
    mapping(address => Airline) private airlines;                                       // mapping of all registered airlines
    mapping(bytes32 => Flight) private flights;                                         // mapping of all registered flights
    mapping(address => uint256) private passengerCredits;                               // Credit relate to passengers

    mapping(address => uint256) private authorizedContracts;                            // Authorize contracts

    /********************************************************************************************/
    /*                                 STRUCTS && ENUMS                                         */
    /********************************************************************************************/

    struct Airline {
        string name;                                                                    // name of air line
        address payable airlineAddress;                                                 // airline address
        uint fund;                                                                      // the fund airline submit
        AirlineState airlineState;                                                      // State of airline
        address[] approveAirlines;                                                      // airlines approve for this airline to be registered
    }

    enum AirlineState {
        Registering,
        Registered,
        Actived
    }

    struct Flight {
        string flight;
        bool isRegistered;
        uint8 statusCode;
        uint256 updatedTimestamp;
        address airline;
        bool isProcessed;
        address[] insurees;                                                         // customers who purchase insurance of this flight
        mapping(address => uint256) insuranceAmount;                                // insurance amount relate to each insuree
    }

    /********************************************************************************************/
    /*                                       CONSTRUCTORS                                       */
    /********************************************************************************************/

    /**
    * @dev Constructor
    * The deploying account becomes contractOwner.
    */
    constructor
    (
        address payable airlineAddress,
        string memory airlineName
    )
    public
    {
        contractOwner = msg.sender;
        // Init first airline and approve it
        _initFirstAirline(airlineAddress, airlineName);
    }

    /********************************************************************************************/
    /*                                       EVENT DEFINITIONS                                  */
    /********************************************************************************************/

    // The airline is registering.
    event Registering(address airline);

    // The airline has become registered.
    event Registered(address airline);

    // The airline has become actived.
    event Actived(address airline);

    // Flight is registed.
    event FlightRegistered(string flight, uint256 timestamp);

    // Customer buy insurance for this flight.
    event InsuranceBought(address airline, string flight, uint256 timestamp);

    // Flight is processed.
    event FlightProcessed(address airline, string flight, uint256 timestamp);

    // Credit payouts to insuree.
    event CreditPayout(address insuree, uint256 amount);

    /********************************************************************************************/
    /*                                       FUNCTION MODIFIERS                                 */
    /********************************************************************************************/

    // Modifiers help avoid duplication of code. They are typically used to validate something
    // before a function is allowed to be executed.

    /**
    * @dev Modifier that requires the "operational" boolean variable to be "true"
    *      This is used on all state changing functions to pause the contract in
    *      the event there is an issue that needs to be fixed
    */
    modifier requireIsOperational()
    {
        require(operational, "Contract is currently not operational");
        _;  // All modifiers require an "_" which indicates where the function body will be added
    }

    /**
    * @dev Modifier that requires the "ContractOwner" account to be the function caller
    */
    modifier requireContractOwner()
    {
        require(msg.sender == contractOwner, "Caller is not contract owner");
        _;
    }

    /**
    * @dev Require the caller is an authorized contract.
    */
    modifier requireAuthorizedContract()
    {
        require(authorizedContracts[msg.sender] == 1, "The caller is not authorized");
        _;
    }

    /**
    * @dev Modifier that stop re-entrancy from happen.
    */
    modifier entrancyGuard()
    {
        entrancyCounter = entrancyCounter.add(1);
        uint256 guard = entrancyCounter;
        _;
        require(guard == entrancyCounter, "Re-entrancy is not allowed");
    }

/**
    * @dev Require the airline is new and has not ever on the queue.
    */
    modifier requireNewAirline(address airline)
    {
        require(airlines[airline].airlineAddress == address(0), "The airline is already on the contract");
        _;
    }

    /**
    * @dev Required the airline is registering.
    */
    modifier requireRegisteringAirline(address airline)
    {
        require(airlines[airline].airlineState == AirlineState.Registering, "The airline is not registering");
        _;
    }

    /**
    * @dev Required the caller is a registered airline.
    */
    modifier requireRegisteredAirline()
    {
        require(airlines[msg.sender].airlineState == AirlineState.Registered, "The caller is not registered");
        _;
    }

    /**
    * @dev Required the caller is an actived airline.
    */
    modifier requireActivedAirline()
    {
        require(airlines[msg.sender].airlineState == AirlineState.Actived, "The caller is not actived");
        _;
    }

    /**
    * @dev Require the caller has not ever approve this airline.
    */
    modifier requireNewApproval(address airline)
    {
        bool duplicated = false;
        address[] memory approveAirlines = airlines[airline].approveAirlines;
        for(uint i = 0; i<approveAirlines.length; i++)
            if (approveAirlines[i] == msg.sender)
            {
                duplicated = true;
                break;
            }
        require(duplicated == false, "Duplicate approval found");
        _;
    }

    /**
    * @dev Require the caller have enough sufficent fund of 10 ether
    */
    modifier requireMin10Ether()
    {
        require(msg.value >= 10 ether, "Insufficient fund");
        _;
    }

    /**
    * @dev Require the caller to submit up to 1 ether.
    */
    modifier requireMax1Ether()
    {
        require(msg.value <= 1 ether, "Fund limit up to 1 ether");
        _;
    }

    /**
    * Require the caller is new insuree for this flight.
    */
    modifier requireNewBuyer(address airline, string memory flight, uint256 timestamp)
    {
        bytes32 key = _getFlightKey(airline, flight, timestamp);
        require(flights[key].insuranceAmount[msg.sender] == 0, "Flight insurance already bought");
        _;
    }

    /**
    * Require the caller is new insuree for this flight.
    */
    modifier requireFlightNotProcessed(address airline, string memory flight, uint256 timestamp)
    {
        bytes32 key = _getFlightKey(airline, flight, timestamp);
        require(flights[key].isProcessed == false, "Flight is already processed");
        _;
    }

    /**
    * Require the passenger has positive credit to withdraw.
    */
    modifier requirePositiveCredit()
    {
        require(passengerCredits[msg.sender] > 0, "The caller does not have positive credit");
        _;
    }

    /********************************************************************************************/
    /*                                       UTILITY FUNCTIONS                                  */
    /********************************************************************************************/

    /**
    * @dev Get operating status of contract
    * @return A bool that is the current operating status
    */      
    function isOperational()
    public
    view
    returns(bool)
    {
        return operational;
    }

    /**
    * @dev Sets contract operations on/off
    *
    * When operational mode is disabled, all write transactions except for this one will fail
    */    
    function setOperatingStatus
    (
        bool mode
    )
    external
    requireContractOwner
    {
        operational = mode;
    }

    /**
    * @dev Initialize first airline when deploy the contract
    */
    function _initFirstAirline
    (
        address payable airlineAddress,
        string memory airlineName
    )
    private
    {
        Airline memory airline;
        airline.airlineAddress = airlineAddress;
        airline.name = airlineName;
        airline.airlineState = AirlineState.Registered;
        airlines[airlineAddress] = airline;
        airlines[airlineAddress].approveAirlines.push(msg.sender);

        emit Registered(airlineAddress);
    }

    /**
    * @dev Taking parameter to init an airline object and add it to a queue.
    * 
    */
    function _initAirline
    (
        address payable airlineAddress,
        string memory airlineName
    )
    private
    {
        Airline memory airline;
        airline.airlineAddress = airlineAddress;
        airline.name = airlineName;
        airline.airlineState = AirlineState.Registering;
        airlines[airlineAddress] = airline;
    }

    /**
    * @dev Assess the registration of an airline.
    * If totalAirline is less than 5, the registration is approved, else, requires multi-party consensus of 50% of registered airlines.
    */
    function _assessRegistration
    (
        address airlineAddress
    )
    private
    {
        if (totalAirlines <= 4 || airlines[airlineAddress].approveAirlines.length.mul(2) >= totalAirlines)
        {
            airlines[airlineAddress].airlineState = AirlineState.Registered;
            emit Registered(airlineAddress);
        }
        else
            emit Registering(airlineAddress);
    }

    /**
    * The caller approve registration of this airline.
    * Add the caller to approve list of this airline.
    */
    function _approveAirline
    (
        address airlineAddress
    )
    private
    {
        airlines[airlineAddress].approveAirlines.push(msg.sender);
    }

    /**
    * @dev Create a unique bytes32 value from parameters.
    */
    function _getFlightKey
    (
        address airline,
        string memory flight,
        uint256 timestamp
    )
    private
    pure
    returns(bytes32)
    {
        return keccak256(abi.encodePacked(airline, flight, timestamp));
    }

    /**
    * @dev Initialize and return flight object.
    */
    function _initFlight
    (
        address airline,
        string memory flightName,
        uint256 timestamp
    )
    private
    pure
    returns (Flight memory flight)
    {
        flight.flight = flightName;
        flight.updatedTimestamp = timestamp;
        flight.airline = airline;
        flight.isRegistered = true;
    }

    /**
    *  @dev Credits payouts to insurees in case airline fault.
    */
    function _creditInsurees
    (
        bytes32 key
    )
    private
    {
        // Find insuree for this flight and credit them 1.5x
        address[] memory insurees = flights[key].insurees;
        for (uint i=0; i < insurees.length; i++)
        {
            uint256 amount = flights[key].insuranceAmount[insurees[i]];
            uint256 credit = amount.mul(3).div(2);
            passengerCredits[insurees[i]] = passengerCredits[insurees[i]].add(credit);
        }
    }

    /********************************************************************************************/
    /*                                     SMART CONTRACT FUNCTIONS                             */
    /********************************************************************************************/

    /**
    * @dev The contract owner authorize this caller.
    */
    function authorizeCaller
    (
        address contractAddress
    )
    external
    requireIsOperational
    requireContractOwner
    {
        authorizedContracts[contractAddress] = 1;
    }

    /**
    * @dev The contract owner deauthorize this caller.
    */
    function deauthorizedContract
    (
        address contractAddress
    )
    external
    requireIsOperational
    requireContractOwner
    {
        delete authorizedContracts[contractAddress];
    }

    /**
    * @dev Check if an address is an airline.
    */
    function isAirline
    (
        address airline
    )
    external
    view
    requireIsOperational
    returns(bool)
    {
        return airlines[airline].airlineAddress != address(0);
    }

   /**
    * @dev Add an airline to the registration queue
    * Can only be called from FlightSuretyApp contract
    */
    function registerAirline
    (
        address payable airlineAddress,
        string calldata airlineName
    )
    external
    requireIsOperational
    requireNewAirline(airlineAddress)
    requireActivedAirline
    {
        _initAirline(airlineAddress, airlineName);
        _approveAirline(airlineAddress);
        _assessRegistration(airlineAddress);
    }

    /**
    * @dev The caller is an active airline approve registration of an airline.
    */
    function approveRegistration
    (
        address airline
    )
    external
    requireIsOperational
    requireActivedAirline
    requireNewApproval(airline)
    {
        _approveAirline(airline);
        _assessRegistration(airline);
    }

    /**
    * @dev A registered airline submit the fund to become actived.
    * Check-Effect-Interaction and Re-entrancy Guard involved.
    */
    function submitFund
    (
    )
    external
    payable
    requireIsOperational
    requireRegisteredAirline
    requireMin10Ether
    entrancyGuard
    {
        uint256 amountToReturn = msg.value.sub(10 ether);
        msg.sender.transfer(amountToReturn);
        airlineFund[msg.sender] = 10 ether;
        totalAirlines = totalAirlines.add(1);

        emit Actived(msg.sender);
    }

    /**
    * @dev An active airline register a flight.
    */
    function registerFlight
    (
        string calldata flightName,
        uint256 timestamp
    )
    external
    requireIsOperational
    requireActivedAirline
    {
        bytes32 key = _getFlightKey(msg.sender, flightName, timestamp);
        Flight memory flight = _initFlight(msg.sender, flightName, timestamp);
        flights[key] = flight;
        emit FlightRegistered(flightName, timestamp);
    }

   /**
    * @dev Customer buy insurance for a flight.
    * Re-entrancy guard is implement.
    */
    function buy
    (
        address airline,
        string calldata flight,
        uint256 timestamp
    )
    external
    payable
    requireIsOperational
    requireMax1Ether
    requireNewBuyer(airline, flight, timestamp)
    requireFlightNotProcessed(airline, flight, timestamp)
    entrancyGuard
    {
        bytes32 key = _getFlightKey(airline, flight, timestamp);
        flights[key].insurees.push(msg.sender);
        flights[key].insuranceAmount[msg.sender] = msg.value;

        emit InsuranceBought(airline, flight, timestamp);
    }

    /**
    * @dev Update flight status of the flight.
    */
    function processFlightStatus
    (
        address airline,
        string calldata flight,
        uint256 timestamp,
        uint8 statusCode,
        bool isAirlineFault  // is flight late because of the airline fault
    )
    external
    requireIsOperational
    requireFlightNotProcessed(airline, flight, timestamp)
    {
        bytes32 key = _getFlightKey(airline, flight, timestamp);
        flights[key].statusCode = statusCode;
        flights[key].isProcessed = true;
        if (isAirlineFault)
            _creditInsurees(key);

        emit FlightProcessed(airline, flight, timestamp);
    }

    /**
    * @dev Transfers eligible payout funds to insuree.
    * Re-entrancy Guard and Check-Effect-Interaction is applied.
    */
    function pay
    (
    )
    external
    payable
    requireIsOperational
    requirePositiveCredit
    entrancyGuard
    {
        uint256 amount = passengerCredits[msg.sender];
        passengerCredits[msg.sender] = 0;
        msg.sender.transfer(amount);

        emit CreditPayout(msg.sender, amount);
    }

   /**
    * @dev Initial funding for the insurance. Unless there are too many delayed flights
    *      resulting in insurance payouts, the contract should be self-sustaining
    *
    */   
    function fund
    (
    )
    public
    payable
    {
    }

    /**
    * @dev Fallback function for funding smart contract.
    *
    */
    function()
    external
    payable
    {
        fund();
    }


}

