from __future__ import annotations
import enum
from difflib import get_close_matches
from fle.env import entities as ent
from fle.commons.space_age import space_age_enabled

# Space Age (DLC) content is only exposed when FLE_SPACE_AGE=1, so the default
# API (and every benchmark prompt generated from it) stays vanilla.
SPACE_AGE = space_age_enabled()


class ResourceName(enum.Enum):
    Coal = "coal"
    IronOre = "iron-ore"
    CopperOre = "copper-ore"
    Stone = "stone"
    Water = "water"
    CrudeOil = "crude-oil"
    UraniumOre = "uranium-ore"

    if SPACE_AGE:
        Calcite = "calcite"  # Vulcanus
        TungstenOre = "tungsten-ore"  # Vulcanus, needs a big mining drill + sulfuric acid
        SulfuricAcidGeyser = "sulfuric-acid-geyser"  # Vulcanus, mine with a pumpjack
        Scrap = "scrap"  # Fulgora, recycle it for holmium and other parts
        LithiumBrine = "lithium-brine"  # Aquilo, mine with a pumpjack
        FluorineVent = "fluorine-vent"  # Aquilo, mine with a pumpjack


class PrototypeMetaclass(enum.EnumMeta):
    def __getattr__(cls, name):
        # Try to get the attribute normally first
        try:
            return cls._member_map_[name]
        except KeyError:
            # Get all valid prototype names
            valid_names = [member.name for member in cls]

            # Find closest matches
            matches = get_close_matches(name, valid_names, n=3, cutoff=0.6)

            suggestion_msg = ""
            if matches:
                suggestion_msg = f". Did you mean: {', '.join(matches)}?"

            raise AttributeError(
                f"'{cls.__name__}' has no attribute '{name}'{suggestion_msg}"
            )


class RecipeName(enum.Enum):
    """
    Recipe names that can be used in the game for fluids
    """

    NuclearFuelReprocessing = "nuclear-fuel-reprocessing"
    UraniumProcessing = "uranium-processing"
    SulfuricAcid = (
        "sulfuric-acid"  # Recipe for producing sulfuric acid with a chemical plant
    )
    BasicOilProcessing = (
        "basic-oil-processing"  # Recipe for producing petroleum gas with a oil refinery
    )
    AdvancedOilProcessing = "advanced-oil-processing"  # Recipe for producing petroleum gas, heavy oil and light oil with a oil refinery
    CoalLiquefaction = (
        "coal-liquefaction"  # Recipe for producing petroleum gas in a oil refinery
    )
    HeavyOilCracking = (
        "heavy-oil-cracking"  # Recipe for producing light oil in a chemical plant
    )
    LightOilCracking = (
        "light-oil-cracking"  # Recipe for producing petroleum gas in a chemical plant
    )

    SolidFuelFromHeavyOil = "solid-fuel-from-heavy-oil"  # Recipe for producing solid fuel in a chemical plant
    SolidFuelFromLightOil = "solid-fuel-from-light-oil"  # Recipe for producing solid fuel in a chemical plant
    SolidFuelFromPetroleumGas = "solid-fuel-from-petroleum-gas"  # Recipe for producing solid fuel in a chemical plant

    FillCrudeOilBarrel = "crude-oil-barrel"
    FillHeavyOilBarrel = "heavy-oil-barrel"
    FillLightOilBarrel = "light-oil-barrel"
    FillLubricantBarrel = "lubricant-barrel"
    FillPetroleumGasBarrel = "petroleum-gas-barrel"
    FillSulfuricAcidBarrel = "sulfuric-acid-barrel"
    FillWaterBarrel = "water-barrel"

    EmptyCrudeOilBarrel = "empty-crude-oil-barrel"
    EmptyHeavyOilBarrel = "empty-heavy-oil-barrel"
    EmptyLightOilBarrel = "empty-light-oil-barrel"
    EmptyLubricantBarrel = "empty-lubricant-barrel"
    EmptyPetroleumGasBarrel = "empty-petroleum-gas-barrel"
    EmptySulfuricAcidBarrel = "empty-sulfuric-acid-barrel"
    EmptyWaterBarrel = "empty-water-barrel"

    if SPACE_AGE:
        # Space Age recipes whose name differs from the item/fluid they produce.
        # Foundry (metallurgy)
        MoltenIronFromLava = "molten-iron-from-lava"
        MoltenCopperFromLava = "molten-copper-from-lava"
        CastingIron = "casting-iron"
        CastingCopper = "casting-copper"
        CastingSteel = "casting-steel"
        CastingIronGearWheel = "casting-iron-gear-wheel"
        CastingIronStick = "casting-iron-stick"
        CastingCopperCable = "casting-copper-cable"
        CastingPipe = "casting-pipe"
        CastingPipeToGround = "casting-pipe-to-ground"
        CastingLowDensityStructure = "casting-low-density-structure"
        ConcreteFromMoltenIron = "concrete-from-molten-iron"
        # Crusher (space platforms)
        MetallicAsteroidCrushing = "metallic-asteroid-crushing"
        CarbonicAsteroidCrushing = "carbonic-asteroid-crushing"
        OxideAsteroidCrushing = "oxide-asteroid-crushing"
        AdvancedMetallicAsteroidCrushing = "advanced-metallic-asteroid-crushing"
        AdvancedCarbonicAsteroidCrushing = "advanced-carbonic-asteroid-crushing"
        AdvancedOxideAsteroidCrushing = "advanced-oxide-asteroid-crushing"
        MetallicAsteroidReprocessing = "metallic-asteroid-reprocessing"
        CarbonicAsteroidReprocessing = "carbonic-asteroid-reprocessing"
        OxideAsteroidReprocessing = "oxide-asteroid-reprocessing"
        # Chemistry / cryogenics
        AcidNeutralisation = "acid-neutralisation"
        SteamCondensation = "steam-condensation"
        IceMelting = "ice-melting"
        CoalSynthesis = "coal-synthesis"
        SimpleCoalLiquefaction = "simple-coal-liquefaction"
        AmmoniacalSolutionSeparation = "ammoniacal-solution-separation"
        SolidFuelFromAmmonia = "solid-fuel-from-ammonia"
        AmmoniaRocketFuel = "ammonia-rocket-fuel"
        AdvancedThrusterFuel = "advanced-thruster-fuel"
        AdvancedThrusterOxidizer = "advanced-thruster-oxidizer"
        Fluoroketone = "fluoroketone"
        FluoroketoneCooling = "fluoroketone-cooling"
        # Biochamber (organic)
        IronBacteriaCultivation = "iron-bacteria-cultivation"
        CopperBacteriaCultivation = "copper-bacteria-cultivation"
        NutrientsFromSpoilage = "nutrients-from-spoilage"
        NutrientsFromYumakoMash = "nutrients-from-yumako-mash"
        NutrientsFromBioflux = "nutrients-from-bioflux"
        NutrientsFromBiterEgg = "nutrients-from-biter-egg"
        NutrientsFromFish = "nutrients-from-fish"
        YumakoProcessing = "yumako-processing"
        JellynutProcessing = "jellynut-processing"
        Bioplastic = "bioplastic"
        Biosulfur = "biosulfur"
        Biolubricant = "biolubricant"
        RocketFuelFromJelly = "rocket-fuel-from-jelly"
        BurntSpoilage = "burnt-spoilage"
        WoodProcessing = "wood-processing"
        FishBreeding = "fish-breeding"


class Prototype(enum.Enum, metaclass=PrototypeMetaclass):
    AssemblingMachine1 = "assembling-machine-1", ent.AssemblingMachine
    AssemblingMachine2 = "assembling-machine-2", ent.AdvancedAssemblingMachine
    AssemblingMachine3 = "assembling-machine-3", ent.AdvancedAssemblingMachine
    Centrifuge = "centrifuge", ent.AssemblingMachine

    BurnerInserter = "burner-inserter", ent.BurnerInserter
    FastInserter = "fast-inserter", ent.Inserter
    # Factorio 2.0: express-inserter removed, filter-inserter removed (all inserters can filter)
    # stack-filter-inserter renamed to bulk-inserter

    LongHandedInserter = "long-handed-inserter", ent.Inserter
    BulkInserter = (
        "bulk-inserter",
        ent.Inserter,
    )  # Factorio 2.0: old stack-inserter renamed to bulk-inserter
    # Backwards compatibility aliases - map to closest equivalent
    if SPACE_AGE:
        # Space Age adds a real stack-inserter (stacks items onto belts)
        StackInserter = "stack-inserter", ent.Inserter
    else:
        StackInserter = (
            "bulk-inserter",
            ent.Inserter,
        )  # Factorio 2.0: old stack-inserter renamed to bulk-inserter
    FilterInserter = (
        "fast-inserter",
        ent.Inserter,
    )  # Factorio 2.0: filter-inserter removed, use fast-inserter
    StackFilterInserter = (
        "bulk-inserter",
        ent.Inserter,
    )  # Factorio 2.0: renamed to bulk-inserter

    Inserter = "inserter", ent.Inserter

    BurnerMiningDrill = "burner-mining-drill", ent.BurnerMiningDrill
    ElectricMiningDrill = "electric-mining-drill", ent.ElectricMiningDrill

    StoneFurnace = "stone-furnace", ent.Furnace
    SteelFurnace = "steel-furnace", ent.Furnace
    ElectricFurnace = "electric-furnace", ent.ElectricFurnace

    Splitter = "splitter", ent.Splitter
    FastSplitter = "fast-splitter", ent.Splitter
    ExpressSplitter = "express-splitter", ent.Splitter

    Rail = "rail", ent.Rail   # the ITEM (craft it); the 2.x entities are below
    StraightRail = "straight-rail", ent.Rail
    HalfDiagonalRail = "half-diagonal-rail", ent.Rail
    CurvedRailA = "curved-rail-a", ent.Rail
    CurvedRailB = "curved-rail-b", ent.Rail

    TransportBelt = "transport-belt", ent.TransportBelt
    FastTransportBelt = "fast-transport-belt", ent.TransportBelt
    ExpressTransportBelt = "express-transport-belt", ent.TransportBelt
    ExpressUndergroundBelt = "express-underground-belt", ent.UndergroundBelt
    FastUndergroundBelt = "fast-underground-belt", ent.UndergroundBelt
    UndergroundBelt = "underground-belt", ent.UndergroundBelt
    OffshorePump = "offshore-pump", ent.OffshorePump
    PumpJack = "pumpjack", ent.PumpJack
    Pump = "pump", ent.Pump
    Boiler = "boiler", ent.Boiler
    OilRefinery = "oil-refinery", ent.OilRefinery
    ChemicalPlant = "chemical-plant", ent.ChemicalPlant

    SteamEngine = "steam-engine", ent.Generator
    SolarPanel = "solar-panel", ent.SolarPanel

    UndergroundPipe = "pipe-to-ground", ent.Pipe
    HeatPipe = "heat-pipe", ent.Pipe
    Pipe = "pipe", ent.Pipe

    SteelChest = "steel-chest", ent.Chest
    IronChest = "iron-chest", ent.Chest
    WoodenChest = "wooden-chest", ent.Chest
    IronGearWheel = "iron-gear-wheel", ent.Entity
    StorageTank = "storage-tank", ent.StorageTank

    SmallElectricPole = "small-electric-pole", ent.ElectricityPole
    MediumElectricPole = "medium-electric-pole", ent.ElectricityPole
    BigElectricPole = "big-electric-pole", ent.ElectricityPole

    Coal = "coal", None
    Wood = "wood", None
    Sulfur = "sulfur", None
    IronOre = "iron-ore", None
    CopperOre = "copper-ore", None
    Stone = "stone", None
    Concrete = "concrete", None
    UraniumOre = "uranium-ore", None

    IronPlate = "iron-plate", None  # Crafting requires smelting 1 iron ore
    IronStick = "iron-stick", None
    SteelPlate = "steel-plate", None  # Crafting requires smelting 5 iron plates
    CopperPlate = "copper-plate", None  # Crafting requires smelting 1 copper ore
    StoneBrick = "stone-brick", None  # Crafting requires smelting 2 stone
    CopperCable = "copper-cable", None
    PlasticBar = "plastic-bar", None
    EmptyBarrel = "empty-barrel", None
    Battery = "battery", None
    SulfuricAcid = "sulfuric-acid", None
    Uranium235 = "uranium-235", None
    Uranium238 = "uranium-238", None

    Lubricant = "lubricant", None
    PetroleumGas = "petroleum-gas", None
    AdvancedOilProcessing = (
        "advanced-oil-processing",
        None,
    )  # These are recipes, not prototypes.
    CoalLiquifaction = "coal-liquifaction", None  # These are recipes, not prototypes.
    SolidFuel = "solid-fuel", None  # These are recipes, not prototypes.
    LightOil = "light-oil", None
    HeavyOil = "heavy-oil", None

    ElectronicCircuit = "electronic-circuit", None
    AdvancedCircuit = "advanced-circuit", None
    ProcessingUnit = "processing-unit", None
    EngineUnit = "engine-unit", None
    ElectricEngineUnit = "electric-engine-unit", None

    Lab = "lab", ent.Lab
    Accumulator = "accumulator", ent.Accumulator
    GunTurret = "gun-turret", ent.GunTurret

    PiercingRoundsMagazine = "piercing-rounds-magazine", ent.Ammo
    FirearmMagazine = "firearm-magazine", ent.Ammo
    Grenade = "grenade", None
    RepairPack = "repair-pack", None

    Radar = "radar", ent.Entity
    StoneWall = "stone-wall", ent.Entity
    Gate = "gate", ent.Entity
    SmallLamp = "small-lamp", ent.Entity

    NuclearReactor = "nuclear-reactor", ent.Reactor
    UraniumFuelCell = "uranium-fuel-cell", None
    HeatExchanger = "heat-exchanger", ent.HeatExchanger

    AutomationSciencePack = "automation-science-pack", None
    MilitarySciencePack = "military-science-pack", None
    LogisticsSciencePack = "logistic-science-pack", None
    ProductionSciencePack = "production-science-pack", None
    UtilitySciencePack = "utility-science-pack", None
    ChemicalSciencePack = "chemical-science-pack", None

    ProductivityModule = "productivity-module", None
    ProductivityModule2 = "productivity-module-2", None
    ProductivityModule3 = "productivity-module-3", None

    FlyingRobotFrame = "flying-robot-frame", None

    RocketSilo = "rocket-silo", ent.RocketSilo
    Rocket = "rocket", ent.Rocket
    Satellite = "satellite", None
    RocketPart = "rocket-part", None
    RocketControlUnit = "rocket-control-unit", None
    LowDensityStructure = "low-density-structure", None
    RocketFuel = "rocket-fuel", None
    SpaceSciencePack = "space-science-pack", None

    BeltGroup = "belt-group", ent.BeltGroup
    PipeGroup = "pipe-group", ent.PipeGroup
    ElectricityGroup = "electricity-group", ent.ElectricityGroup

    # Logistic Chests
    PassiveProviderChest = "passive-provider-chest", ent.LogisticChest
    ActiveProviderChest = "active-provider-chest", ent.LogisticChest
    StorageChest = "storage-chest", ent.LogisticChest
    RequesterChest = "requester-chest", ent.LogisticChest
    BufferChest = "buffer-chest", ent.LogisticChest

    # Beacon
    Beacon = "beacon", ent.Beacon

    # Modules (items only)
    SpeedModule = "speed-module", None
    SpeedModule2 = "speed-module-2", None
    SpeedModule3 = "speed-module-3", None
    EfficiencyModule = "efficiency-module", None
    EfficiencyModule2 = "efficiency-module-2", None
    EfficiencyModule3 = "efficiency-module-3", None

    # Power
    Substation = "substation", ent.ElectricityPole
    SteamTurbine = "steam-turbine", ent.Generator

    # Circuit Network
    ArithmeticCombinator = "arithmetic-combinator", ent.Combinator
    DeciderCombinator = "decider-combinator", ent.Combinator
    ConstantCombinator = "constant-combinator", ent.Combinator
    PowerSwitch = "power-switch", ent.Combinator
    ProgrammableSpeaker = "programmable-speaker", ent.Entity

    # Trains
    TrainStop = "train-stop", ent.TrainStop
    RailSignal = "rail-signal", ent.RailSignal
    RailChainSignal = "rail-chain-signal", ent.RailSignal
    Locomotive = "locomotive", ent.RollingStock
    CargoWagon = "cargo-wagon", ent.RollingStock
    FluidWagon = "fluid-wagon", ent.RollingStock

    # Logistics
    Roboport = "roboport", ent.Roboport

    # Defense
    LaserTurret = "laser-turret", ent.Turret
    FlamethrowerTurret = "flamethrower-turret", ent.FluidTurret
    ArtilleryTurret = "artillery-turret", ent.Turret
    LandMine = "land-mine", ent.Entity

    # Vehicles
    Car = "car", ent.Vehicle
    Tank = "tank", ent.Vehicle
    Spidertron = "spidertron", ent.Vehicle

    if SPACE_AGE:
        # ---- Space Age / Quality / Elevated Rails buildings ----
        Foundry = "foundry", ent.Foundry
        ElectromagneticPlant = "electromagnetic-plant", ent.ElectromagneticPlant
        CryogenicPlant = "cryogenic-plant", ent.CryogenicPlant
        Biochamber = "biochamber", ent.Biochamber
        Crusher = "crusher", ent.Crusher
        CaptiveBiterSpawner = "captive-biter-spawner", ent.CaptiveBiterSpawner
        Recycler = "recycler", ent.Recycler
        BigMiningDrill = "big-mining-drill", ent.BigMiningDrill
        Biolab = "biolab", ent.Biolab
        AgriculturalTower = "agricultural-tower", ent.AgriculturalTower
        HeatingTower = "heating-tower", ent.HeatingTower
        FusionReactor = "fusion-reactor", ent.FusionReactor
        FusionGenerator = "fusion-generator", ent.FusionGenerator
        LightningRod = "lightning-rod", ent.LightningRod
        LightningCollector = "lightning-collector", ent.LightningCollector
        TurboTransportBelt = "turbo-transport-belt", ent.TransportBelt
        TurboUndergroundBelt = "turbo-underground-belt", ent.UndergroundBelt
        TurboSplitter = "turbo-splitter", ent.Splitter
        RocketTurret = "rocket-turret", ent.RocketTurret
        RailgunTurret = "railgun-turret", ent.RailgunTurret
        TeslaTurret = "tesla-turret", ent.TeslaTurret
        RailSupport = "rail-support", ent.RailSupport
        RailRamp = "rail-ramp", ent.RailRamp
        ElevatedStraightRail = "elevated-straight-rail", ent.Rail
        ElevatedHalfDiagonalRail = "elevated-half-diagonal-rail", ent.Rail
        ElevatedCurvedRailA = "elevated-curved-rail-a", ent.Rail
        ElevatedCurvedRailB = "elevated-curved-rail-b", ent.Rail
        # Space platform only
        AsteroidCollector = "asteroid-collector", ent.AsteroidCollector
        CargoBay = "cargo-bay", ent.CargoBay
        Thruster = "thruster", ent.Thruster
        SpacePlatformFoundation = "space-platform-foundation", None
        SpacePlatformStarterPack = "space-platform-starter-pack", None

        # ---- Space Age items ----
        # Science
        MetallurgicSciencePack = "metallurgic-science-pack", None
        ElectromagneticSciencePack = "electromagnetic-science-pack", None
        AgriculturalSciencePack = "agricultural-science-pack", None
        CryogenicSciencePack = "cryogenic-science-pack", None
        PromethiumSciencePack = "promethium-science-pack", None
        # Vulcanus
        Calcite = "calcite", None
        TungstenOre = "tungsten-ore", None
        TungstenPlate = "tungsten-plate", None
        TungstenCarbide = "tungsten-carbide", None
        # Fulgora
        Scrap = "scrap", None
        HolmiumOre = "holmium-ore", None
        HolmiumPlate = "holmium-plate", None
        Supercapacitor = "supercapacitor", None
        Superconductor = "superconductor", None
        # Gleba
        Yumako = "yumako", None
        YumakoMash = "yumako-mash", None
        YumakoSeed = "yumako-seed", None
        Jellynut = "jellynut", None
        Jelly = "jelly", None
        JellynutSeed = "jellynut-seed", None
        TreeSeed = "tree-seed", None
        Bioflux = "bioflux", None
        Nutrients = "nutrients", None
        Spoilage = "spoilage", None
        IronBacteria = "iron-bacteria", None
        CopperBacteria = "copper-bacteria", None
        BiterEgg = "biter-egg", None
        PentapodEgg = "pentapod-egg", None
        Carbon = "carbon", None
        CarbonFiber = "carbon-fiber", None
        ArtificialYumakoSoil = "artificial-yumako-soil", None
        ArtificialJellynutSoil = "artificial-jellynut-soil", None
        OvergrowthYumakoSoil = "overgrowth-yumako-soil", None
        OvergrowthJellynutSoil = "overgrowth-jellynut-soil", None
        # Aquilo
        Ice = "ice", None
        Lithium = "lithium", None
        LithiumPlate = "lithium-plate", None
        QuantumProcessor = "quantum-processor", None
        FusionPowerCell = "fusion-power-cell", None
        IcePlatform = "ice-platform", None
        Foundation = "foundation", None
        # Space
        MetallicAsteroidChunk = "metallic-asteroid-chunk", None
        CarbonicAsteroidChunk = "carbonic-asteroid-chunk", None
        OxideAsteroidChunk = "oxide-asteroid-chunk", None
        PromethiumAsteroidChunk = "promethium-asteroid-chunk", None
        # Quality modules
        QualityModule = "quality-module", None
        QualityModule2 = "quality-module-2", None
        QualityModule3 = "quality-module-3", None
        # Ammo
        TeslaAmmo = "tesla-ammo", ent.Ammo
        RailgunAmmo = "railgun-ammo", ent.Ammo

        # ---- Space Age fluids ----
        Lava = "lava", None
        MoltenIron = "molten-iron", None
        MoltenCopper = "molten-copper", None
        HolmiumSolution = "holmium-solution", None
        Electrolyte = "electrolyte", None
        Ammonia = "ammonia", None
        AmmoniacalSolution = "ammoniacal-solution", None
        LithiumBrine = "lithium-brine", None
        Fluorine = "fluorine", None
        FluoroketoneHot = "fluoroketone-hot", None
        FluoroketoneCold = "fluoroketone-cold", None
        FusionPlasma = "fusion-plasma", None
        ThrusterFuel = "thruster-fuel", None
        ThrusterOxidizer = "thruster-oxidizer", None

    def __init__(self, prototype_name, entity_class_name):
        self.prototype_name = prototype_name
        self.entity_class = entity_class_name

    @property
    def WIDTH(self):
        return self.entity_class._width.default  # Access the class attribute directly

    @property
    def HEIGHT(self):
        return self.entity_class._height.default


prototype_by_name = {prototype.value[0]: prototype for prototype in Prototype}
prototype_by_title = {str(prototype): prototype for prototype in Prototype}


class Technology(enum.Enum):
    # Science pack technologies (Factorio 2.0 prerequisites)
    SteamPower = "steam-power"  # Starting tech, no prerequisites
    AutomationSciencePack = "automation-science-pack"  # Requires steam-power

    # Basic automation technologies
    Automation = "automation"  # Unlocks assembling machine 1
    Automation2 = "automation-2"  # Unlocks assembling machine 2
    Automation3 = "automation-3"  # Unlocks assembling machine 3

    # Logistics technologies
    Logistics = "logistics"  # Unlocks basic belts and inserters
    Logistics2 = "logistics-2"  # Unlocks fast belts and inserters
    Logistics3 = "logistics-3"  # Unlocks express belts and inserters

    # Circuit technologies
    CircuitNetwork = "circuit-network"
    AdvancedCircuit = "advanced-circuit"
    ProcessingUnit = "processing-unit"

    # Backwards-compatible aliases for the Factorio 1.x names. The values must
    # still resolve to real Factorio 2.0 technology prototypes.
    AdvancedElectronics = "advanced-circuit"
    AdvancedElectronics2 = "processing-unit"

    # Power technologies
    Electronics = "electronics"
    ElectricEnergy = "electric-energy-distribution-1"
    ElectricEnergy2 = "electric-energy-distribution-2"
    SolarEnergy = "solar-energy"
    ElectricEngineering = "electric-engine"
    BatteryTechnology = "battery"
    AdvancedBattery = "battery-mk2-equipment"
    NuclearPower = "nuclear-power"

    # Mining technologies
    SteelProcessing = "steel-processing"
    AdvancedMaterialProcessing = "advanced-material-processing"
    AdvancedMaterialProcessing2 = "advanced-material-processing-2"

    # Military technologies
    MilitaryScience = "military"
    MilitaryScience2 = "military-2"
    # MilitaryScience3 = "military-3"
    # MilitaryScience4 = "military-4"
    # Artillery = "artillery"
    # Flamethrower = "flamethrower"
    # LandMines = "land-mines"
    # Turrets = "turrets"
    # LaserTurrets = "laser-turrets"
    # RocketSilo = "rocket-silo"

    # Armor and equipment
    ModularArmor = "modular-armor"
    PowerArmor = "power-armor"
    PowerArmor2 = "power-armor-mk2"
    NightVision = "night-vision-equipment"
    EnergyShield = "energy-shield-equipment"
    EnergyShield2 = "energy-shield-mk2-equipment"

    # Train technologies
    RailwayTransportation = "railway"
    # AutomatedRailTransportation = "automated-rail-transportation"
    # RailSignals = "rail-signals"

    # Oil processing
    OilGathering = "oil-gathering"
    OilProcessing = "oil-processing"
    AdvancedOilProcessing = "advanced-oil-processing"
    SulfurProcessing = "sulfur-processing"
    Plastics = "plastics"
    Lubricant = "lubricant"

    # Modules
    # Modules = "modules"
    # SpeedModule = "speed-module"
    # SpeedModule2 = "speed-module-2"
    # SpeedModule3 = "speed-module-3"
    ProductivityModule = "productivity-module"
    ProductivityModule2 = "productivity-module-2"
    ProductivityModule3 = "productivity-module-3"
    # EfficiencyModule = "efficiency-module"
    # EfficiencyModule2 = "efficiency-module-2"
    # EfficiencyModule3 = "efficiency-module-3"

    # Robot technologies
    Robotics = "robotics"
    # ConstructionRobotics = "construction-robotics"
    # LogisticRobotics = "logistic-robotics"
    # LogisticSystem = "logistic-system"
    # CharacterLogisticSlots = "character-logistic-slots"
    # CharacterLogisticSlots2 = "character-logistic-slots-2"

    # Science technologies
    LogisticsSciencePack = "logistic-science-pack"
    MilitarySciencePack = "military-science-pack"
    ChemicalSciencePack = "chemical-science-pack"
    ProductionSciencePack = "production-science-pack"
    UtilitySciencePack = "utility-science-pack"
    # SpaceSciencePack = "space-science-pack"

    # Inserter technologies
    FastInserter = "fast-inserter"
    BulkInserter = "bulk-inserter"
    StackInserter = "bulk-inserter"
    StackInserterCapacity1 = "inserter-capacity-bonus-1"
    StackInserterCapacity2 = "inserter-capacity-bonus-2"

    # Storage technologies
    StorageTanks = "fluid-handling"
    # Warehouses = "warehousing"

    # Vehicle technologies
    # Automobiles = "automobilism"
    # TankTechnology = "tank"
    # SpiderVehicle = "spidertron"

    # Weapon technologies
    Grenades = "military-2"
    # ClusterGrenades = "cluster-grenades"
    # RocketLauncher = "rocketry"
    # ExplosiveRocketry = "explosive-rocketry"
    # AtomicBomb = "atomic-bomb"
    # CombatRobotics = "combat-robotics"
    # CombatRobotics2 = "combat-robotics-2"
    # CombatRobotics3 = "combat-robotics-3"

    # Misc technologies
    Landfill = "landfill"
    Toolbelt = "toolbelt"
    ResearchSpeed = "research-speed-1"
    StoneWall = "stone-wall"
    Engine = "engine"
    # BrakinPower = "braking-force"

    # # Endgame technologies
    SpaceScience = "space-science-pack"
    RocketFuel = "rocket-fuel"
    LowDensityStructure = "low-density-structure"
    RocketSiloTechnology = "rocket-silo"

    if SPACE_AGE:
        # ---- Space Age: space travel and planets ----
        SpacePlatform = "space-platform"
        SpacePlatformThruster = "space-platform-thruster"
        PlanetDiscoveryVulcanus = "planet-discovery-vulcanus"
        PlanetDiscoveryFulgora = "planet-discovery-fulgora"
        PlanetDiscoveryGleba = "planet-discovery-gleba"
        PlanetDiscoveryAquilo = "planet-discovery-aquilo"
        AdvancedAsteroidProcessing = "advanced-asteroid-processing"
        AsteroidReprocessing = "asteroid-reprocessing"
        # Vulcanus
        Foundry = "foundry"
        BigMiningDrill = "big-mining-drill"
        CalciteProcessing = "calcite-processing"
        TungstenCarbide = "tungsten-carbide"
        TungstenSteel = "tungsten-steel"
        MetallurgicSciencePack = "metallurgic-science-pack"
        TurboTransportBelt = "turbo-transport-belt"
        # Fulgora
        Recycling = "recycling"
        HolmiumProcessing = "holmium-processing"
        ElectromagneticPlant = "electromagnetic-plant"
        ElectromagneticSciencePack = "electromagnetic-science-pack"
        LightningCollector = "lightning-collector"
        # Gleba
        Agriculture = "agriculture"
        Yumako = "yumako"
        Jellynut = "jellynut"
        Biochamber = "biochamber"
        Bioflux = "bioflux"
        BiofluxProcessing = "bioflux-processing"
        BacteriaCultivation = "bacteria-cultivation"
        ArtificialSoil = "artificial-soil"
        OvergrowthSoil = "overgrowth-soil"
        TreeSeeding = "tree-seeding"
        FishBreeding = "fish-breeding"
        CarbonFiber = "carbon-fiber"
        AgriculturalSciencePack = "agricultural-science-pack"
        Biolab = "biolab"
        Captivity = "captivity"
        CaptiveBiterSpawner = "captive-biter-spawner"
        BiterEggHandling = "biter-egg-handling"
        # Aquilo
        LithiumProcessing = "lithium-processing"
        CryogenicPlant = "cryogenic-plant"
        CryogenicSciencePack = "cryogenic-science-pack"
        QuantumProcessor = "quantum-processor"
        FusionReactor = "fusion-reactor"
        Foundation = "foundation"
        HeatingTower = "heating-tower"
        PromethiumSciencePack = "promethium-science-pack"
        # Quality
        QualityModule = "quality-module"
        QualityModule2 = "quality-module-2"
        QualityModule3 = "quality-module-3"
        EpicQuality = "epic-quality"
        LegendaryQuality = "legendary-quality"
        # Logistics / military / misc
        StackInserterTech = "stack-inserter"
        TransportBeltCapacity1 = "transport-belt-capacity-1"
        TransportBeltCapacity2 = "transport-belt-capacity-2"
        ElevatedRail = "elevated-rail"
        RailSupportFoundations = "rail-support-foundations"
        RocketTurret = "rocket-turret"
        TeslaWeapons = "tesla-weapons"
        Railgun = "railgun"
        MechArmor = "mech-armor"
        ToolbeltEquipment = "toolbelt-equipment"
        ResearchProductivity = "research-productivity"


# Helper dictionary to look up technology by name string
technology_by_name = {tech.value: tech for tech in Technology}


class Resource:
    Coal = "coal", ent.ResourcePatch
    IronOre = "iron-ore", ent.ResourcePatch
    CopperOre = "copper-ore", ent.ResourcePatch
    Stone = "stone", ent.ResourcePatch
    Water = "water", ent.ResourcePatch
    CrudeOil = "crude-oil", ent.ResourcePatch
    UraniumOre = "uranium-ore", ent.ResourcePatch
    Wood = "wood", ent.ResourcePatch

    if SPACE_AGE:
        Calcite = "calcite", ent.ResourcePatch
        TungstenOre = "tungsten-ore", ent.ResourcePatch
        SulfuricAcidGeyser = "sulfuric-acid-geyser", ent.ResourcePatch
        Scrap = "scrap", ent.ResourcePatch
        LithiumBrine = "lithium-brine", ent.ResourcePatch
        FluorineVent = "fluorine-vent", ent.ResourcePatch
