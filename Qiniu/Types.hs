{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
module Qiniu.Types where

import ClassyPrelude
import qualified Data.ByteString.Base64.URL as B64U
import qualified Data.Aeson.TH              as AT
import qualified Data.Text.Encoding         as TE

import Data.Time.Clock.POSIX                (utcTimeToPOSIXSeconds)
import Data.Aeson                           (FromJSON, ToJSON, toJSON, object, (.=))
import Data.Time                            (NominalDiffTime, addUTCTime)
import Network.URI                          (isUnreserved, escapeURIString)


newtype Bucket = Bucket { unBucket :: String }
                deriving (Eq, Ord, Show)

newtype ResourceKey = ResourceKey { unResourceKey :: String }
                deriving (Eq, Ord, Show, FromJSON, ToJSON)

data Scope = Scope Bucket (Maybe ResourceKey)
                deriving (Eq, Ord)

encodedScopeUri :: Scope -> ByteString
encodedScopeUri (Scope bucket m_key) =
    B64U.encode $ fromString $ unBucket bucket ++
                    case m_key of
                        Just key -> ":" ++ unResourceKey key
                        Nothing -> ""

instance Show Scope where
    show (Scope bucket m_key) =
        case m_key of
            Nothing -> unBucket bucket
            Just key -> concat [ unBucket bucket, ":", unResourceKey key ]

instance ToJSON Scope where
    toJSON = toJSON . show


type Entry = (Bucket, ResourceKey)

encodedEntryUri :: Entry -> ByteString
encodedEntryUri (bucket, key) =
    B64U.encode $ TE.encodeUtf8 $ fromString $ unBucket bucket ++ ":" ++ unResourceKey key


-- | 所有持久化数据处理指令
class PersistFop a where
  encodeFopToText :: a -> Text

data SomePersistFop = forall a. PersistFop a => SomePersistFop a

instance PersistFop SomePersistFop where
  encodeFopToText (SomePersistFop x) = encodeFopToText x

encodeFopToText' :: PersistFop a => a -> Maybe Entry -> Text
encodeFopToText' x m_save_entry =
  case m_save_entry of
    Nothing -> s
    Just entry -> s <> "|saveas/" <> decodeUtf8 (encodedEntryUri entry)
  where
    s = encodeFopToText x

type FopCmd = (SomePersistFop, Maybe Entry)

encodeFopCmdList :: [FopCmd] -> Text
encodeFopCmdList ops =
  mconcat $ intersperse ";" $ map (uncurry encodeFopToText') ops

data PutPolicy = PutPolicy {
                    ppScope             :: Scope
                    , ppSaveKey         :: Maybe ResourceKey
                    , ppDeadline        :: UTCTime
                }

instance ToJSON PutPolicy where
    toJSON pp =
        object
            [ "scope"       .= ppScope pp
            , "saveKey"     .= fmap unResourceKey (ppSaveKey pp)
            , "deadline"    .= (round $ utcTimeToPOSIXSeconds $ ppDeadline pp :: Int64)
            ]


mkPutPolicy :: MonadIO m =>
    Scope
    -> Maybe ResourceKey    -- ^ the 'saveKey' field
    -> NominalDiffTime -> m PutPolicy
mkPutPolicy scope save_key dt = liftIO $ do
    now <- getCurrentTime
    let t = addUTCTime dt now
    return $ PutPolicy scope save_key t

newtype SecretKey = SecretKey { unSecretKey :: ByteString }
                    deriving (Eq, Ord, Show)

newtype AccessKey = AccessKey { unAccessKey :: ByteString }
                    deriving (Eq, Ord, Show)

newtype AccessToken = AccessToken { unAccessToken :: ByteString }
                    deriving (Eq, Ord, Show)


-- | 上传文件及抓取第三方资源都返回这样的值
data UploadedFileInfo = UploadedFileInfo {
                            ufiHash     :: String
                            , ufiKey    :: ResourceKey
                        }
                        deriving (Eq, Show)

$(AT.deriveJSON
    AT.defaultOptions{AT.fieldLabelModifier = toLower . drop 3}
    ''UploadedFileInfo)


logSource :: IsString a => a
logSource = "QiNiu"


-- | 大部分时候，资源 key 的字串直接就可以拼接在 URL 里
-- 但有些时候要做 url 转义
-- 见 http://kb.qiniu.com/52slk76w
-- 这些情况包括：
-- 首字符是 /
-- 连续出现的 /
-- 其它特殊字符 ? & 之类
-- 这些特殊情况是本来就应该避免的。
-- 这里的算法与文档所述并不完全一致，但按逻辑推理应该是可用的。
-- 这个函数的效果是让以下的恒等式成立。
-- unEscapeString (keyToUrlPath (ResourceKey k)) == '/' : k
keyToUrlPath :: ResourceKey -> String
keyToUrlPath (ResourceKey key) = '/' : esc parts
    where
        parts = splitWhen (== '/') key

        esc []      = ""
        esc ("":[]) = ""
        esc (x:xs)  =   let t = esc xs
                            s = if null x
                                    then "%2F"
                                    else escapeURIString isUnreserved x ++
                                            (if null t && xs /= [""] then "" else "/")
                         in s ++ t
