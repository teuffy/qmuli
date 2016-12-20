{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}

module Qi.Config.AWS.ApiGw.ApiAuthorizer.Accessors where

import           Control.Lens
import           Data.Char            (isAlphaNum)
import qualified Data.HashMap.Strict  as SHM
import           Data.Text            (Text)
import qualified Data.Text            as T

import           Qi.Config.AWS
import           Qi.Config.AWS.ApiGw
import           Qi.Config.Identifier


makeAlphaNumeric :: Text -> Text
makeAlphaNumeric = T.filter isAlphaNum

getApiAuthorizerLogicalName
  :: ApiAuthorizer
  -> Text
getApiAuthorizerLogicalName auth = T.concat [makeAlphaNumeric $ auth^.aaName, "ApiAuthorizer"]

getApiAuthorizerById
  :: ApiAuthorizerId
  -> Config
  -> ApiAuthorizer
getApiAuthorizerById aaid config =
  case SHM.lookup aaid aaMap of
    Just ar -> ar
    Nothing -> error $ "Could not reference api resource with id: " ++ show aaid
  where
    aaMap = config^.apiGwConfig.acApiAuthorizers

getApiAuthorizers
  :: ApiId
  -> Config
  -> [ApiAuthorizerId]
getApiAuthorizers aid config = SHM.lookupDefault [] aid $ config^.apiGwConfig.acApiAuthorizerDeps


