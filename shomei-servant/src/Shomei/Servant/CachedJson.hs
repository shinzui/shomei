{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}

-- | A JSON document and its once-forced wire representation. The private constructor
-- keeps the parsed document and bytes consistent. Used by shared HTTP assembly, including
-- embedded hosts; clients can recover the ordinary Value with 'cachedJsonValue'.
module Shomei.Servant.CachedJson (CachedJson, cacheJson, cachedJsonValue, cachedJsonBytes) where

import Data.Aeson (FromJSON (..), ToJSON (..), Value, encode)
import Data.ByteString.Lazy qualified as LBS
import Servant.API (JSON, MimeRender (..))

data CachedJson = CachedJson !Value !LBS.ByteString deriving (Eq, Show)

cacheJson :: Value -> CachedJson
cacheJson value = CachedJson value (LBS.fromStrict (LBS.toStrict (encode value)))

cachedJsonValue :: CachedJson -> Value
cachedJsonValue (CachedJson value _) = value

cachedJsonBytes :: CachedJson -> LBS.ByteString
cachedJsonBytes (CachedJson _ bytes) = bytes

instance ToJSON CachedJson where
  toJSON = cachedJsonValue

instance FromJSON CachedJson where
  parseJSON value = pure (cacheJson value)

instance {-# OVERLAPPING #-} MimeRender JSON CachedJson where
  mimeRender _ = cachedJsonBytes
