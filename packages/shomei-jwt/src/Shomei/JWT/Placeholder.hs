{-# LANGUAGE PackageImports #-}

{- | JWT package placeholder. Imports 'Shomei.Prelude' to verify cross-package
prelude use. EP-6 replaces this with real JWT signing/verification.
-}
module Shomei.JWT.Placeholder (
    packageName,
    exampleText,
) where

import Shomei.Prelude

packageName :: String
packageName = "shomei-jwt"

{- | A trivial use of 'Text' from 'Shomei.Prelude', proving the prelude is importable
across packages.
-}
exampleText :: Text
exampleText = "shomei-jwt placeholder"
