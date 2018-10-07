--------------------------------------------------------------------------------
-- |
-- Module      :  Language.ILC.TypeError
-- Copyright   :  (C) 2018 Kevin Liao
-- License     :  BSD-style (see LICENSE)
-- Maintainer  :  Kevin Liao (kliao6@illinois.edu)
-- Stability   :  experimental
--
-- Describes type errors and implements error messages.
--
--------------------------------------------------------------------------------

module Language.ILC.TypeError (
    TypeError(..)
  ) where

import Text.PrettyPrint.ANSI.Leijen

import Language.ILC.Mode
import Language.ILC.Syntax
import Language.ILC.Type

data TypeError = UnificationFail TM TM
               | InfiniteType TVar Type
               | UnboundVariable Name
               | Ambiguous [(Type, Type)]
               | UnificationMismatch [TM] [TM]
               | ParFail Mode Mode
               | SeqFail Mode Mode
               | ChoiceFail Mode Mode
               | ModeFail String
               | TypeFail String
               | LinearFail

instance Show TypeError where
  show = show . pretty
  
instance Pretty TypeError where
  pretty (UnificationFail a b) =
    hsep [ text "Cannot unify types:\n\t"
         , pretty a
         , text "\nwith\n\t"
         , pretty b
         ]
  
  pretty (InfiniteType (TV a) b) =
    hsep [ text "Cannot construct the infinite type:"
         , pretty a
         , text "="
         , pretty b
         ]
         
  pretty (Ambiguous cs) =
    hsep [ hsep [ text "Cannot match expected type:"
                , text "'" <> pretty a <> text "'"
                , text "with actual type:"
                , text "'" <> pretty b <> text "'\n"
                ] | (a, b) <- cs ]
         
  pretty (UnboundVariable a) = text "Not in scope:" <+> pretty a

  pretty (ParFail m1 m2) =
    hsep [ text "Cannot derive mode composition:"
         , pretty m1
         , text "|"
         , pretty m2
         ]

  pretty (SeqFail m1 m2) =
    hsep [ text "Cannot derive mode composition:"
         , pretty m1
         , text ";"
         , pretty m2
         ]

  pretty (ChoiceFail m1 m2) =
    hsep [ text "Subexpressions of choice have mode R.\n"
         , text "Given:"
         , pretty m1
         , text "and"
         , pretty m2
         ]
    
  pretty (ModeFail s) = text s
  
  pretty (TypeFail s)  = text s
  
  pretty LinearFail  = text "Linear read channel violation."
