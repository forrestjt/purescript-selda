module Test.PG where

import Prelude

import Data.Date (Date, canonicalDate)
import Data.Either (Either(..))
import Data.Enum (toEnum)
import Data.Maybe (Maybe(..), fromJust, isJust)
import Database.PostgreSQL (PoolConfiguration, defaultPoolConfiguration)
import Database.PostgreSQL as PostgreSQL
import Effect (Effect)
import Effect.Aff (launchAff)
import Effect.Class (liftEffect)
import Global.Unsafe (unsafeStringify)
import Partial.Unsafe (unsafePartial)
import Selda (Table(..), lit, not_, restrict, selectFrom, (.==), (.>))
import Selda.PG (litF)
import Selda.PG.Class (deleteFrom, insert1_, insert_, update)
import Selda.Table.Constraint (Auto, Default)
import Test.Common (bankAccounts, descriptions, legacySuite, people)
import Test.Types (AccountType(..))
import Test.Unit (failure, suite)
import Test.Unit.Main (runTest)
import Test.Utils (assertSeqEq, assertUnorderedSeqEq, runSeldaAff, testWith, testWithPG)

employees ∷ Table
  ( id ∷ Auto Int
  , name ∷ String
  , salary ∷ Default Int
  , date ∷ Default Date
  )
employees = Table { name: "employees" }

date ∷ Int → Int → Int → Date
date y m d = unsafePartial $ fromJust $
  canonicalDate <$> toEnum y <*> toEnum m <*> toEnum d

testSuite ctx = do
  let
    unordered = assertUnorderedSeqEq
    ordered = assertSeqEq

  testWith ctx unordered "employees inserted with default and without salary"
    [ { id: 1, name: "E1", salary: 123, date: date 2000 10 20 }
    , { id: 2, name: "E2", salary: 500, date: date 2000 11 21 }
    -- , { id: 3, name: "E3", salary: 500, date: date 2000 12 22 }
    ]
    $ selectFrom employees \r → do
        restrict $ not_ $ r.date .> (litF $ date 2000 11 21)
        pure r

main ∷ Effect Unit
main = do
  pool ← PostgreSQL.newPool dbconfig
  void $ launchAff do
    PostgreSQL.withConnection pool case _ of
      Left pgError → failure ("PostgreSQL connection error: " <> unsafeStringify pgError)
      Right conn → do
        createdb ← PostgreSQL.execute conn (PostgreSQL.Query """
          DROP TABLE IF EXISTS people;
          CREATE TABLE people (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            age INTEGER
          );

          DO $$
          BEGIN
            IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'account_type') THEN
              CREATE TYPE ACCOUNT_TYPE as ENUM (
                'business',
                'personal'
              );
            END IF;
          END$$;

          DROP TABLE IF EXISTS bank_accounts;
          CREATE TABLE bank_accounts (
            id INTEGER PRIMARY KEY,
            personId INTEGER NOT NULL,
            balance INTEGER NOT NULL,
            accountType ACCOUNT_TYPE NOT NULL
          );

          DROP TABLE IF EXISTS descriptions;
          CREATE TABLE descriptions (
            id INTEGER PRIMARY KEY,
            text TEXT
          );

          DROP TABLE IF EXISTS emptyTable;
          CREATE TABLE emptyTable (
            id INTEGER PRIMARY KEY
          );

          DROP TABLE IF EXISTS employees;
          CREATE TABLE employees (
            id SERIAL PRIMARY KEY,
            name TEXT NOT NULL,
            salary INTEGER DEFAULT 500,
            date DATE NOT NULL DEFAULT '2000-10-20'
          );
        """) PostgreSQL.Row0
        when (isJust createdb) $
          failure ("PostgreSQL createdb error: " <> unsafeStringify createdb)

        runSeldaAff conn do
          insert_ people
            [ { id: 1, name: "name1", age: Just 11 }
            , { id: 2, name: "name2", age: Just 22 }
            , { id: 3, name: "name3", age: Just 33 }
            ]
          insert_ bankAccounts
            [ { id: 1, personId: 1, balance: 100, accountType: Business }
            , { id: 2, personId: 1, balance: 150, accountType: Personal }
            , { id: 3, personId: 3, balance: 300, accountType: Personal }
            ]
          insert_ descriptions
            [ { id: 1, text: Just "text1" }
            , { id: 3, text: Nothing }
            ]
          -- id is Auto, so it cannot be inserted
          -- insert_ employees [{ id: 1, name: "E1", salary: 123 }]
          insert_ employees [{ name: "E1", salary: 123 }]
          insert1_ employees { name: "E2", date: date 2000 11 21 }
          insert1_ employees { name: "E3" }

        -- simple test delete
        runSeldaAff conn do
          insert1_ people { id: 4, name: "delete", age: Just 999 }
          deleteFrom people \r → r.id .== lit 4

        -- simple test update
        runSeldaAff conn do
          insert1_ people { id: 5, name: "update", age: Just 999 }
          update people
            (\r → r.name .== lit "update")
            (\r → r { age = lit $ Just 1000 })
          deleteFrom people \r → r.age .> lit (Just 999)

          update employees
            (\r → r.name .== lit "E3")
            (\r → r { date = litF $ date 2000 12 22 })

        liftEffect $ runTest $ do
          suite "Selda.PG" $ testWithPG conn legacySuite
          suite "Selda.PG.Specific" $ testWithPG conn testSuite

dbconfig ∷ PoolConfiguration
dbconfig = (defaultPoolConfiguration "purspg")
  { user = Just "init"
  , password = Just $ "qwerty"
  , idleTimeoutMillis = Just $ 1000
  }
