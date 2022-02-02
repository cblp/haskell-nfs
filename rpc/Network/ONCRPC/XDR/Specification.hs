-- |XDR specification, as per RFC4506 and RPC extensions from RFC5531

module Network.ONCRPC.XDR.Specification
  where

import qualified Network.ONCRPC.XDR.Types as XDR
import qualified Network.ONCRPC.Types as RPC

data ArrayLength
  = FixedLength    { arrayLength :: !XDR.Length }
  | VariableLength { arrayLength :: !XDR.Length -- ^defaulted to maxLength
    }
  deriving (Show)

data TypeDescriptor
  = TypeSingle
    { descriptorType :: !TypeSpecifier
    }
  | TypeArray
    { descriptorType :: !TypeSpecifier
    , descriptorLength :: !ArrayLength
    }
  | TypeOpaque
    { descriptorLength :: !ArrayLength
    }
  | TypeString
    { descriptorLength :: !ArrayLength -- ^only 'VariableArray'
    }
  | TypeOptional
    { descriptorType :: !TypeSpecifier
    }
  deriving (Show)

data TypeSpecifier
  = TypeInt
  | TypeUnsignedInt
  | TypeHyper
  | TypeUnsignedHyper
  | TypeFloat
  | TypeDouble
  | TypeQuadruple
  | TypeBool
  | TypeEnum !EnumBody
  | TypeStruct !StructBody
  | TypeUnion !UnionBody
  | TypeIdentifier !String
  deriving (Show)

-- |Non-void declaration
data Declaration = Declaration
  { declarationIdentifier :: !String
  , declarationType :: TypeDescriptor
  }
  deriving (Show)

-- |'Declaration' or void
type OptionalDeclaration = Maybe Declaration

type EnumValues = [(String, XDR.Int)]

newtype EnumBody = EnumBody
  { enumValues :: EnumValues
  }
  deriving (Show)

boolValues :: EnumValues
boolValues = [("FALSE", 0), ("TRUE", 1)]

newtype StructBody = StructBody
  { structMembers :: [Declaration] -- ^with voids elided
  }
  deriving (Show)

data UnionArm = UnionArm
  { unionCaseIdentifier :: String -- ^The literal string found after "case", for labeling
  , unionDeclaration :: OptionalDeclaration
  }
  deriving (Show)

data UnionBody = UnionBody
  { unionDiscriminant :: !Declaration
  , unionCases :: [(XDR.Int, UnionArm)]
  , unionDefault :: Maybe UnionArm
  }
  deriving (Show)

data Procedure = Procedure
  { procedureRes :: Maybe TypeSpecifier
  , procedureIdentifier :: !String
  , procedureArgs :: [TypeSpecifier]
  , procedureNumber :: !RPC.ProcNum
  }

data Version = Version
  { versionIdentifier :: !String
  , versionTypeIdentifier :: !String
  , versionProcedures :: [Procedure]
  , versionNumber :: !RPC.VersNum
  }

data DefinitionBody
  = TypeDef TypeDescriptor
  | Constant Integer
  | Program
    { programTypeIdentifier :: !String
    , programVersions :: [Version]
    , programNumber :: !RPC.ProgNum
    }

data Definition = Definition
  { definitionIdentifier :: !String
  , definitionBody :: !DefinitionBody
  }

type Specification = [Definition]
