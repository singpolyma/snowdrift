module Version (mkVersion) where

import Import

import System.IO
import System.IO.Temp

import Language.Haskell.TH

getVersion :: IO (String, String)
getVersion = withSystemTempFile "version" $ \ _ handle -> do
    hClose handle
    return ("base", "diff")


mkVersion :: Q Exp
mkVersion = do
    (base, diff) <- runIO  getVersion
    return $ TupE $ map (LitE . StringL) [ base, diff ]

