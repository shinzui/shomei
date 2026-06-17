{- | The bundled common-password dictionary and the membership check.

The dictionary is embedded at COMPILE time from @data/common-passwords.txt@ via
Template Haskell ('embedStringFile'), parsed once into a 'Set' of normalized entries
(a top-level CAF), and queried by 'isCommonPassword'. Matching is case-insensitive
exact membership: the input is trimmed and lowercased, then looked up in the set. It is
NOT a substring scan.
-}
module Shomei.Domain.CommonPasswords (
    isCommonPassword,
    commonPasswordCount,
) where

import Shomei.Prelude

import Data.FileEmbed (embedStringFile, makeRelativeToProject)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as Text

-- | The raw embedded file contents (compile-time splice, path anchored at the package dir).
rawDictionary :: Text
rawDictionary = $(makeRelativeToProject "data/common-passwords.txt" >>= embedStringFile)

{- | The dictionary as a set of normalized entries. Blank lines and lines beginning
with @#@ (comments / the operator note) are ignored. Built once as a CAF.
-}
commonPasswords :: Set Text
commonPasswords =
    Set.fromList
        [ normalized
        | line <- Text.lines rawDictionary
        , let normalized = Text.toLower (Text.strip line)
        , not (Text.null normalized)
        , not ("#" `Text.isPrefixOf` Text.strip line)
        ]

-- | Number of dictionary entries (used by tests to assert the set is non-empty).
commonPasswordCount :: Int
commonPasswordCount = Set.size commonPasswords

{- | Is the given password a known common password? Case-insensitive exact membership:
the input is trimmed and lowercased before lookup.
-}
isCommonPassword :: Text -> Bool
isCommonPassword pw = Text.toLower (Text.strip pw) `Set.member` commonPasswords
