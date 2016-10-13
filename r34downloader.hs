{-# OPTIONS_GHC -O2
    -rtsopts
    -Wall
    -fno-warn-unused-do-bind
    -fno-warn-type-defaults
    -fexcess-precision
    -optc-O3
    -optc-ffast-math
    -fforce-recomp #-}

import Network.HTTP (getResponseBody, simpleHTTP, getResponseBody,
                        defaultGETRequest_)
import Network.URI (parseURI)
import Text.HTML.TagSoup
import qualified Data.ByteString as B (writeFile)
import Data.Maybe (fromMaybe)
import System.Directory (getCurrentDirectory, doesDirectoryExist)
import Data.Char (isNumber)
import Control.Concurrent.Thread.Delay (delay)
import Text.Printf (printf)
import System.Environment (getArgs)
import System.IO (hFlush, stdout)
import Control.Concurrent.Async (async, wait)
import Control.Exception (try, SomeException)
import Text.Read (readMaybe)
import System.FilePath.Posix (addTrailingPathSeparator, takeExtension)
import Search (search)
import Utilities

main :: IO ()
main = do
    args <- getArgs
    if any (`elem` helpFlags) args then help else
        if any (`elem` searchFlags) args then search args else do
    url <- askURL
    dir <- getDir
    firstpage <- try (openURL url) :: IO (Either SomeException String)
    case firstpage of
        Left _ -> putStrLn noInternet
        Right val -> if noImagesExist val then putStrLn (noImages url) else do
        let lastpage = desiredSection start end getPageNum val
            urls = allURLs url lastpage
            start = "<section id='paginator'>"
            end = "</section"
        links <- takeNLinks args <$> getLinks urls
        niceDownload dir links

type URL = String

{-
Start is the tag you want to find the links in, End is the closing tag,
the function is for specifying what to get once the links have been isolated
-}
desiredSection :: String -> String -> ([[Attribute String]] -> a)
                    -> String -> a
desiredSection start end f page = fromMain $ parseTags page
    where fromMain = f . getHyperLinks . local
          local = takeWhile (~/= end) . dropWhile (~/= start)

getText :: Tag t -> [Attribute t]
getText (TagOpen _ stuff) = stuff
getText _ = error "Only use with a TagOpen."

{-
Hyperlinks all start with the "a" identifier, this means we will get less crud
or have less filtering to do later
-}
getHyperLinks :: [Tag String] -> [[Attribute String]]
getHyperLinks = map getText . filter (isTagOpenName "a")

--Extracts image links from an attribute
getImageLink :: [[(a, String)]] -> [URL]
getImageLink xs = filter isImage links
    where links = map (snd . last) xs
          isImage x = takeExtension x `elem` filetypes

{-
From https://stackoverflow.com/questions/11514671/
     haskell-network-http-incorrectly-downloading-image/11514868
-}
downloadImage :: FilePath -> URL -> IO ()
downloadImage directory url = do
    image <- get
    B.writeFile filename image
    where get = let uri = fromMaybe (error $ "Invalid URI: " ++ url)
                            (parseURI url)
                in simpleHTTP (defaultGETRequest_ uri) >>= getResponseBody
          filename = removeEscapeSequences $ name directory url

{-
Extract the file name of the image from the url and add it to the directory
path so we can rename files. We truncate to 255 characters because
openBinaryFile errors on a filename length over 256. We ensure we retain the 
directory path and the filename. Note that this will probably fail if the dir
length is over 255. Not sure if filesystems even support that though.
-}
name :: FilePath -> URL -> FilePath
name directory url
    | length xs + len > maxFileNameLen = directory ++ desired
    | otherwise = directory ++ xs
    where xs = reverse . takeWhile (/= '/') $ reverse url
          maxFileNameLen = 255
          len = maxFileNameLen - length directory
          desired = reverse (take len (reverse xs))

--Gets the last page available so we get every link from 1 to last page
getPageNum :: [[(a, String)]] -> Int
getPageNum xs
    | length xs <= 2 = 1 --only one page long - will error on !!
    | otherwise = read $ reverse $ takeWhile isNumber $ reverse desired
    where desired = snd $ last $ xs !! 2

{-
We use init to drop the '1' at the end of the url and replace it with 
the current page number. It's easier to remove it here than to add it in
a few other places
-}
allURLs :: URL -> Int -> [URL]
allURLs url lastpage = map (addPageNum baseURL) [1..lastpage]
    where addPageNum xs n = xs ++ show n
          baseURL = init url

{-
Gets all the image links so we can download them, once every second so
website doesn't block us
-}
getLinks :: [URL] -> IO [URL]
getLinks [] = return []
getLinks (x:xs) = do
    input <- openURL x 
    let links = desiredSection start end getImageLink input
        start = "<section id='imagelist'>"
        end = "</section"
    printf "%d links added to download...\n" (length links)
    delay oneSecond
    nextlinks <- getLinks xs
    return (links ++ nextlinks)

--Add a delay to our download to not get rate limited
niceDownload :: FilePath -> [URL] -> IO ()
niceDownload dir links = niceDownload' links 1
    where num = length links
          niceDownload' :: [URL] -> Int -> IO () 
          niceDownload' [] _ = return ()
          niceDownload' (link:rest) x = do
            img <- async $ downloadImage dir link
            printf "Downloading %d out of %d: %s\n" x num 
                    (removeEscapeSequences link)
            delay oneSecond
            niceDownload' rest (succ x)
            wait img

askURL :: IO URL
askURL = do
    args <- getArgs
    let maybeURL = getFlagValue args tagFlags
    let pretty x = addBaseAddress (filter isAllowedChar (map replaceSpace x))
    case maybeURL of
        Nothing -> promptTag
        Just url -> return $ pretty url

help :: IO ()
help = putStr =<< readFile "help.txt"

promptTag :: IO String
promptTag = do
    putStr "Enter the tag which you wish to download: "
    hFlush stdout
    addBaseAddress . filter isAllowedChar . map replaceSpace <$> getLine

--Check that images exist for the specified tag
noImagesExist :: String -> Bool
noImagesExist page
    | null $ findError $ parseTags page = False
    | otherwise = True
    where findError = dropWhile (~/= "<section id='Errormain'>")

takeNLinks :: [String] -> [URL] -> [URL]
takeNLinks args links =
    case maybeN of
        Just x -> take x links
        Nothing -> links
    where maybeN = readMaybe =<< getFlagValue args firstFlags

getDir :: IO FilePath
getDir = do
    args <- getArgs
    cwd <- addTrailingPathSeparator <$> getCurrentDirectory
    let def = return cwd
        maybeDir = getFlagValue args directoryFlags
    case maybeDir of
        Nothing -> def
        Just dir -> do
        isDir <- doesDirectoryExist dir
        if isDir
            then return (addTrailingPathSeparator dir)
            else def
