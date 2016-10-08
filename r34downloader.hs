{-# OPTIONS_GHC -O2
    -rtsopts
    -Wall
    -fno-warn-unused-do-bind
    -fno-warn-type-defaults
    -fexcess-precision
    -optc-O3
    -optc-ffast-math
    -fforce-recomp #-}

import Network.HTTP (getResponseBody, simpleHTTP, getRequest, getResponseBody, defaultGETRequest_)
import Network.URI (parseURI)
import Text.HTML.TagSoup
import Data.List (isSuffixOf, elemIndex, isPrefixOf, lines)
import qualified Data.ByteString as B (writeFile)
import Data.Maybe (fromMaybe, mapMaybe, isNothing, fromJust)
import System.Directory (getCurrentDirectory, doesDirectoryExist)
import Data.Char (isNumber, isAlphaNum, toLower)
import Control.Concurrent.Thread.Delay (delay)
import Text.Printf (printf)
import System.Environment (getArgs)
import System.IO (hFlush, stdout)
import Control.Concurrent.Async (async, wait)
import Control.Exception (try, SomeException)
import Text.Read (readMaybe)
import System.FilePath.Posix (addTrailingPathSeparator)

{-
This program is a tool to quickly rip all the images from a given tag on
rule34.paheal. It is not super fast due to the website limiting requests to one
per second. Use the --help or -h flag for help.
-}
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
        let lastpage = desiredSection "<section id='paginator'>" "</section" getPageNum val
            urls = allURLs url lastpage
        links <- takeNLinks args <$> getLinks urls
        niceDownload dir links

type URL = String

openURL :: URL -> IO String
openURL x = getResponseBody =<< simpleHTTP (getRequest x)

{-
Start is the tag you want to find the links in, End is the closing tag,
the function is for specifying what to get once the links have been isolated
-}
desiredSection :: String -> String -> ([[Attribute String]] -> a) -> String -> a
desiredSection start end f page = fromMain $ parseTags page
    where fromMain = f . getHyperLinks . takeWhile (~/= end) . dropWhile (~/= start)

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
getImageLink = map (snd . last) . filter (\x -> any (`isSuffixOf` snd (last x)) filetypes)

filetypes :: [String]
filetypes = [".jpg", ".png", ".gif", ".jpeg"]

{-
From https://stackoverflow.com/questions/11514671/
     haskell-network-http-incorrectly-downloading-image/11514868
-}
downloadImage :: FilePath -> URL -> IO ()
downloadImage directory url = do
    image <- get
    B.writeFile (name directory url) image
    where get = let uri = fromMaybe (error $ "Invalid URI: " ++ url) (parseURI url)
                in simpleHTTP (defaultGETRequest_ uri) >>= getResponseBody

{-
Extract the file name of the image from the url and add it to the directory
path so we can rename files. We truncate to 255 characters because
openBinaryFile errors on a filename length over 256. We ensure we retain the 
directory path and the filename. Note that this will probably fail if the dir
length is over 255. Not sure if filesystems even support that though.
-}
name :: FilePath -> URL -> FilePath
name directory url
    | length xs + len > maxFileNameLen = directory ++ reverse (take len (reverse xs))
    | otherwise = directory ++ xs
    where xs = reverse . takeWhile (/= '/') $ reverse url
          maxFileNameLen = 255
          len = maxFileNameLen - length directory

--Gets the last page available so we get every link from 1 to last page
getPageNum :: [[(a, String)]] -> Int
getPageNum xs
    | length xs <= 2 = 1 --only one page long - will error on !!
    | otherwise = read $ dropWhile (not . isNumber) $ snd $ last $ xs !! 2

{-
We use init to drop the '1' at the end of the url and replace it with 
the current page number. It's easier to remove it here than to add it in
a few other places
-}
allURLs :: URL -> Int -> [URL]
allURLs url lastpage = map (f (init url)) [1..lastpage]
    where f xs n = xs ++ show n

{-
Gets all the image links so we can download them, once every second so
website doesn't block us
-}
getLinks :: [URL] -> IO [URL]
getLinks [] = return []
getLinks (x:xs) = do
    input <- openURL x 
    let links = desiredSection "<section id='imagelist'>" "</section" getImageLink input
    printf "%d links added to download...\n" (length links)
    delay oneSecond
    nextlinks <- getLinks xs
    return (links ++ nextlinks)

--Add a delay to our download to not get rate limited
niceDownload :: FilePath -> [URL] -> IO ()
niceDownload _ [] = return ()
niceDownload dir (link:links) = do
    img <- async $ downloadImage dir link
    putStrLn $ "Downloading " ++ link
    delay oneSecond
    niceDownload dir links
    wait img

--1 second in milliseconds
oneSecond :: (Num a) => a
oneSecond = 1000000

askURL :: IO URL
askURL = do
    args <- getArgs
    let maybeURL = getFlagValue args tagFlags
    case maybeURL of
        Nothing -> promptTag
        Just url -> return $ addBaseAddress (filter isAllowedChar (map replace url))

help :: IO ()
help = putStr =<< readFile "help.txt"

promptTag :: IO String
promptTag = do
    putStrLn "Enter the tag which you wish to download."
    putStr "Enter tag: "
    hFlush stdout
    addBaseAddress . filter isAllowedChar . map replace <$> getLine

addBaseAddress :: String -> URL
addBaseAddress xs = "http://rule34.paheal.net/post/list/" ++ xs ++ "/1"

noImages :: URL -> String
noImages = printf "Sorry - no images were found with that tag. (URL: %s) \
            \Ensure you spelt it correctly."

--Check that images exist for the specified tag
noImagesExist :: String -> Bool
noImagesExist page
    | null $ findError $ parseTags page = False
    | otherwise = True
    where findError = dropWhile (~/= "<section id='Errormain'>")

takeNLinks :: [String] -> [URL] -> [URL]
takeNLinks args links = case maybeN of
    Just x -> take (abs x) links
    Nothing -> links
    where maybeN = readMaybe =<< getFlagValue args firstFlags

{-
Gets the value in the argument list following one of the tags specified in flags
if the flag exists in the argument list, and the argument list is long enough
to get the next item in the argument list
-}
getFlagValue :: [String] -> [String] -> Maybe String
getFlagValue [] _ = Nothing
getFlagValue _ [] = Nothing
getFlagValue args flags
    | flagExists && len > val = Just (args !! val)
    | otherwise = Nothing
    where len = length args
          flagExists = any (`elem` flags) args
          val = 1 + head (mapMaybe (`elemIndex` args) flags)

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

allowedChars :: String
allowedChars = '_' : ['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9']

isAllowedChar :: Char -> Bool
isAllowedChar c = c `elem` allowedChars

{-
We use &mincount=1 to add the smaller tags as well as the more popular ones
Tags have to begin with a-z A-Z or 0-9 and not be empty.
-}
search :: [String] -> IO ()
search args
    | isNothing maybeSearchTerm ||
      not (isAlphaNum firstChar) = putStrLn invalidSearchTerm
    | otherwise = do
        eitherPage <- try (openURL url) :: IO (Either SomeException String)
        case eitherPage of
            Left _ -> putStrLn noInternet
            Right page -> do
            let tags = filter (searchTerm `isPrefixOf`) (getTags page)
            case tags of
                [] -> putStrLn noTags
                _ -> mapM_ putStrLn tags
    where maybeSearchTerm = getFlagValue args searchFlags
          searchTerm = map toLower $ fromJust maybeSearchTerm
          firstChar = head searchTerm
          baseURL = "http://rule34.paheal.net/tags?starts_with="
          url = baseURL ++ [firstChar] ++ "&mincount=1"

helpFlags :: [String]
helpFlags = ["--help","-h"]

directoryFlags :: [String]
directoryFlags = ["--directory","-d"]

searchFlags :: [String]
searchFlags = ["--search","-s"]

tagFlags :: [String]
tagFlags = ["--tag","-t"]

firstFlags :: [String]
firstFlags = ["--first","-f"]

invalidSearchTerm :: String
invalidSearchTerm = "No search term entered, or invalid search term entered, exiting."

noTags :: String
noTags = "No tag found with that search term, please try again."

{-
All lines containing a tag are prefixed with the below magic string
We also lower case it all so case sensitivity in searching is no issue
-}
getTags :: String -> [String]
getTags soup = map (map toLower . isolate) tagLines
    where tagLines = filter (isPrefixOf "&nbsp;") (lines soup)

{-
list/ is immediatly before the tag name in the string we extracted earlier
then we take until the next / which terminates the tag
-}
isolate :: String -> String
isolate soup = takeWhile (/= '/') start
    where start = myDrop "list/" soup

{-
ugly....
Searches through string until search term (xs) is found, then takes the
rest of the string after that term
-}
myDrop :: String -> String -> String
myDrop xs ys = myDrop' xs xs ys ys
    where myDrop' _ [] _ bs = bs
          myDrop' _ _ _ [] = []
          myDrop' searchTerm (a:as) soup (b:bs)
            | a == b = myDrop' searchTerm as soup bs
            | otherwise = myDrop' searchTerm searchTerm soup bs

noInternet :: String 
noInternet = "Sorry, we couldn't connect to the website. Check that it's not \
            \down and you have an internet connection."

--Replace spaces with underscores so tag searching is more user friendly
replace :: Char -> Char
replace ' ' = '_'
replace c = c
