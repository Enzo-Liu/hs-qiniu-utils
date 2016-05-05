module Qiniu.PersistOps
  ( PersistentId(..)
  , QiniuPfopMonad
  , AvthumbFormat
  , AvthumbSubOp(..)
  , AvthumbOp(..)
  , PersistOpStatus(..)
  , persistOpStatusFromCode
  , persistOpStatusToCode
  , persistOpStatusSucceeded
  , PersistOpInfo(..)
  , PfopInfoItem(..)
  , persistOpsOnSaved
  , persistOpsQuery
  ) where

import ClassyPrelude
import Control.Lens
import Control.Monad.Logger
import Control.Monad.Except                 (runExceptT, ExceptT(..))
import Data.Aeson
import qualified Network.Wreq.Session       as WS
import Network.Wreq

import Qiniu.Types
import Qiniu.Security
import Qiniu.WS.Types


persistOpsApiUrlBase :: String
persistOpsApiUrlBase = "http://api.qiniu.com"


newtype PersistentId = PersistentId { unPersistentId :: Text }
                        deriving (Eq, Ord, Show, FromJSON, ToJSON)


type QiniuPfopMonad m = (MonadIO m, MonadThrow m, MonadLogger m, MonadReader WS.Session m)



-- | 音视频处理的格式参数
type AvthumbFormat = Text

-- | 音视频处理
data AvthumbSubOp = AvthumbOpBitRate Int        -- ^ /ab/<BitRate>
                  | AvthumbOpAudioQuality Int   -- ^ /aq/<AudioQuality>
                  | AvthumbOpSamplingRate Int   -- ^ 采样频率，单位HZ
                  | AvthumbOpAudioCodec Text    -- ^ 编码方案．如 libx264
                  deriving (Show, Eq, Ord)

encodeAvthumbOpAsPath :: AvthumbSubOp -> Text
encodeAvthumbOpAsPath (AvthumbOpBitRate k)      = "ab/" <> tshow k <> "k"
encodeAvthumbOpAsPath (AvthumbOpAudioQuality q) = "aq/" <> tshow q
encodeAvthumbOpAsPath (AvthumbOpSamplingRate r) = "ar/" <> tshow r
encodeAvthumbOpAsPath (AvthumbOpAudioCodec c) = "ar/" <> c


-- | 音视频处理完整指令
data AvthumbOp = AvthumbOp AvthumbFormat [AvthumbSubOp]

instance PersistFop AvthumbOp where
  encodeFopToText (AvthumbOp format sub_ops) =
    mconcat $ intersperse "/" $ ("avthumb/" <> format) : map encodeAvthumbOpAsPath sub_ops


data PfopResp = PfopResp { unPfopResp :: PersistentId }

instance FromJSON PfopResp where
  parseJSON = withObject "PfopResp" $ \o ->
                PfopResp <$> o .: "persistentId"


-- | 对已有的资源执行持久化数据处理
persistOpsOnSaved :: QiniuPfopMonad m
                  => AccessToken
                  -> [FopCmd]
                  -> Bucket         -- ^ bucket of input resource
                  -> ResourceKey    -- ^ key of input resource
                  -> Maybe Text     -- ^ notify url
                  -> Maybe Pipeline -- ^ pipeline
                  -> Bool
                  -> m (WsResult PersistentId)
persistOpsOnSaved atk ops bucket rkey m_notify_url m_pipeline force = runExceptT $ do
  sess <- ask
  let url = persistOpsApiUrlBase <> "/pfop"
  let fops = encodeFopCmdList ops
  let opts = defaults & wreqOptionsAddAccessTokenHeader atk
      post_data = catMaybes
                    [ Just $ "bucket" := unBucket bucket
                    , Just $ "key" := unResourceKey rkey
                    , Just $ "fops" := fops
                    , flip fmap m_notify_url $ \x -> "notifyURL" := x
                    , flip fmap m_pipeline $ \pl -> "pipeline" := unPipeline pl
                    , if force
                         then Just $ "force" := asText "1"
                         else Nothing
                    ]

  fmap (fmap unPfopResp) $ (asWsResponseNormal' =<<) $
    ExceptT $ liftIO $ try $ WS.postWith opts sess url post_data


-- | 持久化处理结果状态码
data PersistOpStatus =  PersistOpSucceeded
                      | PersistOpPending
                      | PersistOpProcessing
                      | PersistOpFailed
                      | PersistOpNotifyFailed
                      | PersistOpStatusOther Int
                      deriving (Show, Eq)

instance FromJSON PersistOpStatus where
  parseJSON v = persistOpStatusFromCode <$> parseJSON v


persistOpStatusFromCode :: Int -> PersistOpStatus
persistOpStatusFromCode code =
  case code of
    0 -> PersistOpSucceeded
    1 -> PersistOpPending
    2 -> PersistOpProcessing
    3 -> PersistOpFailed
    4 -> PersistOpNotifyFailed
    _ -> PersistOpStatusOther code


persistOpStatusToCode :: PersistOpStatus -> Int
persistOpStatusToCode PersistOpSucceeded      = 0
persistOpStatusToCode PersistOpPending        = 1
persistOpStatusToCode PersistOpProcessing     = 2
persistOpStatusToCode PersistOpFailed         = 3
persistOpStatusToCode PersistOpNotifyFailed   = 4
persistOpStatusToCode(PersistOpStatusOther c) = c


-- | PersistOpNotifyFailed 的意义不明，目前认为这为是处理本身是成功的
-- 只是通知发生错误而已
persistOpStatusSucceeded :: PersistOpStatus -> Bool
persistOpStatusSucceeded PersistOpSucceeded    = True
persistOpStatusSucceeded PersistOpNotifyFailed = True
persistOpStatusSucceeded _                     = False


data PersistOpInfo = PersistOpInfo
  { pfopInfoId          :: PersistentId
  , pfopInfoStatus      :: PersistOpStatus
  , pfopInfoStatusDesc  :: Text
  , pfopInfoInputKey    :: ResourceKey
  , pfopInfoInputBucket :: Bucket
  , pfopInfoItems       :: [ PfopInfoItem ]
  , pfopInfoPipeline    :: Pipeline
  , pfopInfoReqid       :: Text
  }
  deriving (Show)

instance FromJSON PersistOpInfo where
  parseJSON = withObject "PersistOpInfo" $ \o -> do
    PersistOpInfo <$> o .: "id"
                  <*> o .: "code"
                  <*> o .: "desc"
                  <*> o .: "inputKey"
                  <*> (Bucket <$> o .: "inputBucket")
                  <*> o .: "items"
                  <*> o .: "pipeline"
                  <*> o .: "reqid"

data PfopInfoItem = PfopInfoItem
  { pfopInfoItemCmd        :: Text
  , pfopInfoItemStatus     :: PersistOpStatus
  , pfopInfoItemStatusDesc :: Text
  , pfopInfoItemError      :: Text
  , pfopInfoItemHash       :: ByteString
  , pfopInfoItemKey        :: ResourceKey
  , pfopInfoItemReturnOld  :: Bool
  }
  deriving (Show, Eq)

instance FromJSON PfopInfoItem where
  parseJSON = withObject "PfopInfoItem" $ \o -> do
                PfopInfoItem <$> o .: "cmd"
                             <*> o .: "code"
                             <*> o .: "desc"
                             <*> o .: "error"
                             <*> fmap fromString (o .: "hash")
                             <*> o .: "key"
                             <*> (fmap (/= (0 :: Int)) $ o .: "returnOld")


-- | 持久化处理状态查询
persistOpsQuery :: QiniuPfopMonad m
                => PersistentId
                -> m (WsResult PersistOpInfo)
persistOpsQuery pid = runExceptT $ do
  sess <- ask
  let url = persistOpsApiUrlBase <> "/prefop"
      opts = defaults & param "id" .~ [ unPersistentId pid ]

  (asWsResponseNormal' =<<) $
    ExceptT $ liftIO $ try $ WS.getWith opts sess url
