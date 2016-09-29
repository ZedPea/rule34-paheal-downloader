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
import Data.List (isSuffixOf, intercalate, elemIndex)
import qualified Data.ByteString as B (writeFile)
import Data.Maybe (fromMaybe, isJust, mapMaybe)
import System.Directory (getCurrentDirectory, doesDirectoryExist)
import Data.Char (isNumber)
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
    if any (`elem` ["--help","-h"]) args then putStrLn help else do
    url <- askUrl
    dir <- getDir
    firstpage <- try (openURL url) :: IO (Either SomeException String)
    case firstpage of
        Left _ -> putStrLn invalidURL
        Right val -> if noImagesExist val then putStrLn (noImages url) else do
        let lastpage = desiredSection "<section id='paginator'>" "</section" getPageNum val
            urls = allUrls url lastpage
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
getText _ = error "Only use with a TagOpen"

{-
Hyperlinks all start with the "a" identifier, this means we will get less crud
or have less filtering to do later
-}
getHyperLinks :: [Tag String] -> [[Attribute String]]
getHyperLinks = map getText . filter (isTagOpenName "a")

{-
Extract image link from attribute by checking that it is a valid filetype
then taking the head of what we have left. It doesn't actually matter
if we use head or last as the ones which match the pattern are all singleton
lists
-}
getImageLink :: [[(a, String)]] -> [URL]
getImageLink = map (snd . last) . filter (\x -> any (`isSuffixOf` snd (last x)) filetypes)

--I believe these are the only supported filetypes by paheal
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

--Gets all the urls so we can download the pics from them
allUrls :: URL -> Int -> [URL]
allUrls url lastpage = map (f (init url)) [1..lastpage]
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

{-
checks that the arg list is long enough for there to be a tag after the 
tag flag so we don't error on !!
-}
askUrl :: IO URL
askUrl = do
    args <- getArgs
    let flags = ["--tag","-t"]
        index = getElemIndex args flags
    if any (`elem` flags) args && (length args > index)
        then return (addBaseAddress $ args !! index)
        else promptTag

help :: String
help = intercalate "\n" ["This program downloads images of a given \
            \tag from http://rule34.paheal.net.","","Either enter the tag you wish \
            \to download with the flag -t or --tag and then the tag.","Please note \
            \that the tag must not have spaces in to allow the website to query \
            \correctly.","Please use underscores instead.","","For example, the WRONG \
            \way to do it is ./r34downloader -t \"Cute anime girl\".","The CORRECT way \
            \is ./r34downloader -t \"Cute_anime_girl\".","","If you only want to download \
            \the first n images, use the -f or --first flag.","Example: ./r34downloader \
            \--tag \"Cute_anime_girl\" --first 10","This will take the first 10 images \
            \from the tag Cute_anime_girl if 10 exist.","","If you want to download the \
            \images to somewhere otherwise than the current directory, ", "specify that \
            \with the -d or --directory flag.","Example: ./r34downloader --t \"Cute\
            \_anime_girl\" --directory \"/media/Pictures\""]

promptTag :: IO String
promptTag = do
    putStrLn "Enter the tag which you wish to download."
    putStrLn "Note that a tag must not have spaces in, use underscores instead."
    putStr "Enter tag: "
    hFlush stdout
    addBaseAddress <$> getLine

addBaseAddress :: String -> URL
addBaseAddress xs = "http://rule34.paheal.net/post/list/" ++ xs ++ "/1"

noImages :: URL -> String
noImages = printf "Sorry - no images were found with that tag. (URL: %s) \
            \Ensure you spelt it correctly and you used underscores instead of \
            \spaces."

--Check that images exist for the specified tag
noImagesExist :: String -> Bool
noImagesExist page
    | null $ findError $ parseTags page = False
    | otherwise = True
    where findError = dropWhile (~/= "<section id='Errormain'>")

{-
this error occurs with no internet, possibly in other scenarios too, not
sure if we get this with an invalid tag or if that just gets us no images...
-}
invalidURL :: String
invalidURL = "Sorry, that URL wasn't valid! Make sure you didn't include \
                \spaces in your tags, and that your internet connection is working.\
                \\nUse the --help flag for more info."

takeNLinks :: [String] -> [URL] -> [URL]
takeNLinks args links
    | not $ any (`elem` flags) args = links
    | otherwise = case n of
                      Just x -> take (abs x) links
                      Nothing -> links
    where flags = ["-f", "--first"]
          index = getElemIndex args flags
          n = getN args index

--Gets the index of the value after the tag
getElemIndex :: [String] -> [String] -> Int
getElemIndex args flags = 1 + head (mapMaybe (`elemIndex` args) flags)

--Gets the argument at the specified index, if it exists, and is a number
getN :: [String] -> Int -> Maybe Int
getN args index
    | length args > index && isJust num = num
    | otherwise = Nothing
    where num = readMaybe $ args !! index

{-
isDir should be evaluated lazily, and because && short circuits, we
should only reach it when len args > index, so we don't error on !!
-}
getDir :: IO FilePath
getDir = do
    args <- getArgs
    cwd <- addTrailingPathSeparator <$> getCurrentDirectory
    let flags = ["-d", "--directory"]
        def = return cwd
        index = getElemIndex args flags 
    isDir <- doesDirectoryExist (args !! index)
    if any (`elem` flags) args && (length args > index) && isDir
        then return (addTrailingPathSeparator $ args !! index)
        else def
