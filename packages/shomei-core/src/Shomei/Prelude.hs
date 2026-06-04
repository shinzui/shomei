{-# LANGUAGE PackageImports #-}

{- | Shōmei shared prelude. Import this module in every Shōmei module instead of
importing 'Prelude' directly. Every import here uses PackageImports to pin the
originating package and avoid ambiguity when multiple packages re-export the same
name.

Usage:

> import Shomei.Prelude

Do NOT add @import "base" Prelude@ after this; GHC2024 hides the default Prelude
when you write a custom one.
-}
module Shomei.Prelude (
    module X,
    module Control.Lens,
    eventAesonOptions,
) where

import "aeson" Data.Aeson as X (
    FromJSON,
    Options (..),
    SumEncoding (..),
    ToJSON,
    camelTo2,
    defaultOptions,
    fromJSON,
    genericParseJSON,
    genericToEncoding,
    genericToJSON,
    parseJSON,
    toEncoding,
    toJSON,
 )
import "base" Control.Applicative as X ((<|>))
import "base" Control.Monad as X (
    forM,
    forM_,
    guard,
    unless,
    void,
    when,
 )
import "base" Control.Monad.IO.Class as X (MonadIO, liftIO)
import "base" Data.List.NonEmpty as X (NonEmpty (..))
import "base" Data.Maybe as X (
    fromMaybe,
    isJust,
    isNothing,
    mapMaybe,
 )
import "base" Data.Proxy as X (Proxy (..))
import "base" GHC.Generics as X (Generic)
import "lens" Control.Lens
import "text" Data.Text as X (Text)
import "time" Data.Time as X (UTCTime, getCurrentTime)

{- | Aeson 'Options' for event types: tagged objects with snake_case constructor
names and always-tagged single constructors.

Example: @data MyEvent = UserCreated { ... }@ serialises as
@{ "type": "user_created", "data": { ... } }@.
-}
eventAesonOptions :: Options
eventAesonOptions =
    defaultOptions
        { sumEncoding = TaggedObject "type" "data"
        , constructorTagModifier = camelTo2 '_'
        , tagSingleConstructors = True
        }
