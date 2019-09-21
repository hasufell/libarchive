module Codec.Archive.Unpack ( hsEntries
                            , unpackEntriesFp
                            , unpackArchive
                            , readArchiveFile
                            , readArchiveBS
                            , unpackToDir
                            ) where

import           Codec.Archive.Common
import           Codec.Archive.Foreign
import           Codec.Archive.Monad
import           Codec.Archive.Types
import           Control.Monad          (void, (<=<))
import           Control.Monad.IO.Class (MonadIO (..))
import           Data.Bifunctor         (first)
import qualified Data.ByteString        as BS
import           Foreign.C.String
import           Foreign.Marshal.Alloc  (allocaBytes)
import           Foreign.Ptr            (Ptr, nullPtr)
import           System.FilePath        ((</>))
import           System.IO.Unsafe       (unsafePerformIO)

-- | Read an archive contained in a 'BS.ByteString'. The format of the archive is
-- automatically detected.
--
-- @since 1.0.0.0
readArchiveBS :: BS.ByteString -> Either ArchiveResult [Entry]
readArchiveBS = unsafePerformIO . runArchiveM . (hsEntries <=< bsToArchive)
{-# NOINLINE readArchiveBS #-}

bsToArchive :: BS.ByteString -> ArchiveM ArchivePtr
bsToArchive bs = do
    a <- liftIO archiveReadNew
    ignore $ archiveReadSupportFormatAll a
    useAsCStringLenArchiveM bs $
        \(buf, sz) ->
            handle $ archiveReadOpenMemory a buf (fromIntegral sz)
    pure a

-- | Read an archive from a file. The format of the archive is automatically
-- detected.
--
-- @since 1.0.0.0
readArchiveFile :: FilePath -> ArchiveM [Entry]
readArchiveFile = hsEntries <=< archiveFile

archiveFile :: FilePath -> ArchiveM ArchivePtr
archiveFile fp = withCStringArchiveM fp $ \cpath -> do
    a <- liftIO archiveReadNew
    ignore $ archiveReadSupportFormatAll a
    handle $ archiveReadOpenFilename a cpath 10240
    pure a

-- | This is more efficient than
--
-- @
-- unpackToDir "llvm" =<< BS.readFile "llvm.tar"
-- @
unpackArchive :: FilePath -- ^ Filepath pointing to archive
              -> FilePath -- ^ Dirctory to unpack in
              -> ArchiveM ()
unpackArchive tarFp dirFp = do
    a <- archiveFile tarFp
    unpackEntriesFp a dirFp
    ignore $ archiveFree a

readEntry :: ArchivePtr -> Ptr ArchiveEntry -> IO Entry
readEntry a entry =
    Entry
        <$> (peekCString =<< archiveEntryPathname entry)
        <*> readContents a entry
        <*> archiveEntryPerm entry
        <*> readOwnership entry
        <*> readTimes entry

-- | Yield the next entry in an archive
getHsEntry :: MonadIO m => ArchivePtr -> m (Maybe Entry)
getHsEntry a = do
    entry <- liftIO $ getEntry a
    case entry of
        Nothing -> pure Nothing
        Just x  -> Just <$> liftIO (readEntry a x)

-- | Return a list of 'Entry's.
hsEntries :: MonadIO m => ArchivePtr -> m [Entry]
hsEntries a = do
    next <- getHsEntry a
    case next of
        Nothing -> pure []
        Just x  -> (x:) <$> hsEntries a

-- | Unpack an archive in a given directory
unpackEntriesFp :: ArchivePtr -> FilePath -> ArchiveM ()
unpackEntriesFp a fp = do
    res <- liftIO $ getEntry a
    case res of
        Nothing -> pure ()
        Just x  -> do
            preFile <- liftIO $ archiveEntryPathname x
            file <- liftIO $ peekCString preFile
            let file' = fp </> file
            liftIO $ withCString file' $ \fileC ->
                archiveEntrySetPathname x fileC
            ignore $ archiveReadExtract a x archiveExtractTime
            liftIO $ archiveEntrySetPathname x preFile
            ignore $ archiveReadDataSkip a
            unpackEntriesFp a fp

readBS :: ArchivePtr -> Int -> IO BS.ByteString
readBS a sz =
    allocaBytes sz $ \buff ->
        archiveReadData a buff (fromIntegral sz) *>
        BS.packCStringLen (buff, sz)

readContents :: ArchivePtr -> Ptr ArchiveEntry -> IO EntryContent
readContents a entry = go =<< archiveEntryFiletype entry
    where go FtRegular = NormalFile <$> (readBS a =<< sz)
          go FtLink = Symlink <$> (peekCString =<< archiveEntrySymlink entry)
          go FtDirectory = pure Directory
          go _ = error "Unsupported filetype"
          sz = fromIntegral <$> archiveEntrySize entry

archiveGetterHelper :: (Ptr ArchiveEntry -> IO a) -> (Ptr ArchiveEntry -> IO Bool) -> Ptr ArchiveEntry -> IO (Maybe a)
archiveGetterHelper get check entry = do
    check' <- check entry
    if check'
        then Just <$> get entry
        else pure Nothing

archiveGetterNull :: (Ptr ArchiveEntry -> IO CString) -> Ptr ArchiveEntry -> IO (Maybe String)
archiveGetterNull get entry = do
    res <- get entry
    if res == nullPtr
        then pure Nothing
        else fmap Just (peekCString =<< get entry)

readOwnership :: Ptr ArchiveEntry -> IO Ownership
readOwnership entry =
    Ownership
        <$> archiveGetterNull archiveEntryUname entry
        <*> archiveGetterNull archiveEntryGname entry
        <*> (fromIntegral <$> archiveEntryUid entry)
        <*> (fromIntegral <$> archiveEntryGid entry)

readTimes :: Ptr ArchiveEntry -> IO (Maybe ModTime)
readTimes = archiveGetterHelper go archiveEntryMtimeIsSet
    where go entry =
            (,) <$> archiveEntryMtime entry <*> archiveEntryMtimeNsec entry

-- | Get the next 'ArchiveEntry' in an 'Archive'
getEntry :: ArchivePtr -> IO (Maybe (Ptr ArchiveEntry))
getEntry a = do
    let done ArchiveOk    = False
        done ArchiveRetry = False
        done _            = True
    (stop, res) <- first done <$> archiveReadNextHeader a
    pure $ if stop
        then Nothing
        else Just res

unpackToDir :: FilePath -- ^ Directory to unpack in
            -> BS.ByteString -- ^ 'BS.ByteString' containing archive
            -> ArchiveM ()
unpackToDir fp bs = do
    a <- bsToArchive bs
    unpackEntriesFp a fp
    void $ liftIO $ archiveFree a
