port module Main exposing (Model, Msg(..), init, main, subscriptions, update, view)

--  Elm modules import & interfaces {{{

import Array
import Basics
import Browser
import Browser.Events as Events
import Debug
import Dict exposing (Dict)
import Html exposing (Attribute, Html, div, span, text)
import Html.Attributes exposing (..)
import Html.Events exposing (onInput)
import Json.Decode as Decode
import Json.Encode as E
import String
import Tuple


port audio_event : E.Value -> Cmd msg


main : Program () Model Msg
main =
    Browser.element
        { view = view
        , init = \() -> init
        , subscriptions = subscriptions
        , update = update
        }



-- }}}
-- String/Char/Misc utilities and aliases {{{


wall =
    "#"


newLine =
    "\n"



--- TODO It's worth discussing any differences between Strings and list of Chars
--- or how we might use the type system to organize the various char operations
-- Returns the string/char?? at index location.
--- Bamboozling that we need write this.


access : String -> Int -> String
access string index =
    String.slice index (index + 1) string



-- Returns new string with replaced index


set : String -> Int -> String -> String
set string index replace =
    String.slice 0 index string ++ replace ++ String.slice (index + 1) (String.length string) string



-- Aliases for comparison operators, feel free to refactor code so we don't need these if you find it more aesthetic


lt a b =
    b < a


gt a b =
    b > a


lte a b =
    b <= a


gte a b =
    b >= a



-- }}}


type alias Model =
    { world : String
    , point : Int
    , numprefix : Int
    , score : Int
    , stock : Dict String Int
    , levels : List Level
    , level : Int
    }



-- Model: State, Selectors, Mutators {{{


scan : Model -> Int -> String
scan model distance =
    access model.world (model.point + distance)



-- Usage: scan model 0 is under the cursor, scan model +/-1 is forward/backward
-- TODO who wants scan to check for world boundaries? (0 and length of world)


seek : Model -> Int -> Model
seek model distance =
    { model | point = model.point + distance }


type Direction
    = Forward
    | Backward


incr : Direction -> Int
incr dir =
    case dir of
        Forward ->
            1

        Backward ->
            -1


relative : Int -> Int -> Int
relative point index =
    index - point


locate : Direction -> Model -> String -> List Int
locate dir model char =
    let
        index =
            String.indexes char model.world
    in
    List.map (relative model.point) <|
        case dir of
            Forward ->
                List.filter (gte model.point) index

            Backward ->
                List.reverse (List.filter (lte model.point) index)



-- Returns the stream of distances to the given char
-- Refactor so that locate traverses the list. This will let us restrict jumping motions TODO
-- Figure out how get as a stream(lazy list) so that seeking small distances isn't O(n) TODO
-- Figure out how to wrap around world TODO


getcolumn :
    Model
    -> Int -- Gets column of point
getcolumn model =
    case locate Backward model newLine of
        first :: rest ->
            -first

        [] ->
            model.point + 1



--nextrow: Model -> String
--nextrow model =
-- }}}
-- Operator functions


type alias Operator =
    Model -> Model


type Motion
    = Lateral -- Moves point forward/backward by a character
    | Vertical -- Moves point to the previous/next row
    | Jump -- Moves point by jumping to a location



-- Lateral: forward & backward {{{


column : Direction -> Operator
column dir model =
    let
        step =
            incr dir
    in
    if scan model step |> obstructs Lateral then
        model

    else
        seek model step



--- }}}
-- Vertical: upward & downward {{{


upward model =
    let
        col =
            getcolumn model
    in
    case List.take 2 (locate Backward model newLine) of
        a :: b :: rest ->
            if (scan model (b - a) |> obstructs Vertical) || (col > ((a - b) - 1)) then
                model

            else
                seek model (b - a)

        a :: rest ->
            if (access model.world (-a - 1) |> obstructs Vertical) || (model.point + a < -a) then
                model

            else
                { model | point = -a - 1 }

        [] ->
            model


downward model =
    let
        col =
            getcolumn model
    in
    case List.take 2 (locate Forward model newLine) of
        a :: b :: rest ->
            if (b - a) < col || (scan model (col + a) |> obstructs Vertical) then
                model

            else
                seek model (a + col)

        a :: rest ->
            let
                dest =
                    col + a
            in
            if
                (String.length model.world - 1)
                    < (model.point + dest)
                    || (scan model dest |> obstructs Vertical)
            then
                model

            else
                seek model dest

        [] ->
            model



-- TODO the way that these functions access world and point to test edge conditions isn't great
-- Needs a proper line/row abstraction


row : Direction -> Operator
row dir model =
    let
        col =
            getcolumn model
    in
    case locate dir model newLine of
        first :: second :: rest ->
            model

        first :: rest ->
            model

        [] ->
            model



-- TODO actually merge the functions
-- }}}
-- Line: startline & endline {{{


lineEnd : Direction -> Operator
lineEnd dir model =
    case locate dir model newLine of
        car :: cdr ->
            seek model (car - incr dir)

        [] ->
            case dir of
                Forward ->
                    { model | point = String.length model.world - 1 }

                Backward ->
                    { model | point = 0 }



-- TODO Should they travel through obstructions?
-- }}}
-- Find char {{{


find : Direction -> String -> Operator
find dir char model =
    case locate dir model char of
        car :: cdr ->
            seek model car

        [] ->
            model



-- }}}
-- Jump between matching brackets {{{


jumpmatch : Model -> Model
jumpmatch model =
    case scan model 0 of
        "(" ->
            find Forward ")" model

        ")" ->
            find Backward "(" model

        "{" ->
            find Forward "}" model

        "}" ->
            find Backward "{" model

        "<" ->
            find Forward ">" model

        ">" ->
            find Backward "<" model

        "[" ->
            find Forward "]" model

        "]" ->
            find Backward "[" model

        _ ->
            model



-- }}}


replaceChar : String -> Operator
replaceChar string =
    \model -> { model | world = set model.world model.point " " }



-- Functional Operators {{{


pushNumericPrefix : Int -> Model -> Model
pushNumericPrefix num model =
    { model | numprefix = 10 * model.numprefix + num }


clearNumericPrefix model =
    { model | numprefix = 0 }


repeatOp : Operator -> Int -> Operator
repeatOp op times =
    if times > 1 then
        op >> repeatOp op (times - 1)

    else
        op


prefixCompose : Operator -> Operator
prefixCompose op =
    \model -> clearNumericPrefix (repeatOp op model.numprefix model)



-- }}}
-- Gameplay: Motion Obstruction {{{


obstructs : Motion -> String -> Bool
obstructs op char =
    case char of
        "#" ->
            True

        "\n" ->
            True

        _ ->
            case op of
                Lateral ->
                    case char of
                        "|" ->
                            True

                        _ ->
                            False

                Vertical ->
                    case char of
                        "-" ->
                            True

                        _ ->
                            False

                _ ->
                    False



-- }}}
-- Worlds and Levels {{{


type alias Level =
    ( String, Int )


world : Level -> String
world level =
    Tuple.first level


start : Level -> Int
start level =
    Tuple.second level


ascii =
    ( List.range 0 255 |> List.map Char.fromCode |> String.fromList, 65 )


level0 =
    ( "Welcome to level 0 in Vim Adventures Spinoff!\nThis level hopes to encourage you to get comfortable using the basic movement keys: h, j, k, l. \nWalls are comprised of # keys, which you may not move through.\n\nTry to explore the map and get to the finish line!\n\n#######      |\n#  k  #  #   |\n# h l #  |   |\n#  j  #  |   |\n##   ##  |   |\n         |   |\n---------+   |\n             |\n ##-----------\n  -       @  \n#########", 292 )


level1 =
    ( "Welcome to level 1 in Vim Adventures Spinoff!\nThis level hopes to encourage you to get comfortable using the basic movement keys: h, j, k, l. \nWalls are comprised of # keys, which you may not move through.\n\nTry to explore the map and get to the finish line!\n\n###################################################\n#    l ->      #                                  #\n#   ########   # ^ ########   #################   #\n# j #      #   # | #      #   #         <- h      #\n#   #  (:  #   #   #  :)  #   #   #################\n# | #      #   # k #      #   #                   #\n# V ########   #   ########   ################    #\n#                             #                   #\n###############################===#################\n                              FINISH @               \n", 313 )



--top left of box is point 293


level2 =
    ( "Level 2:\nThis level encourages using the beginning and end line keys: ^ and $\nThey allow you to jump forward or backward to the end of a line, which\nmeans you can jump over obstacles!\n\nTry using the ^ and $ keys to jump from wall to wall!\n\n###################################################\n#      $ #    Y O U    #                          -\n###############################################   #\n-              #     S H A L L     # ^            #\n#   ###############################################\n#         #    N O T    #                         -\n##############################################    #\n-                 # P A S S  #                    #\n##====#############################################\n FINISH @                                            \n", 293 )



--top left of box is point 340


level3 =
    ( "Level 3:\nThis level encourages using the % operator.\nThis also a new way to avoid obstacles, by jumping to the matching\nopen or close bracket.\nYou may think of it as a secret tunnel that ends at the other matching bracket.\n\nTry hitting % when you find a bracket to avoid the obstacle!\n\n\n###################################################\n#  % % (  #    Y O U    #             )           #\n###############################################   #\n#       <       #     S H A L L     #     >       #\n#   ###############################################\n#      {    #    N O T    #     }     [           #\n##############################################    #\n#          ]       # P A S S  #                   #\n##====#############################################\n FINISH@                                           \n", 340 )



--top left of box is point 363


level4 =
    ( "Level 4:\nThis level encourages using the numbers!\nNumbers allow you to repeat instructions without pressing the keys\nover and over. If you type a number and then type an action such\nas moving, you will move that many times.\n\nTry using the numbers to help you efficiently move up and down through the maze!\n\n\n#####################################################\n#   #       #       #       #       #       #       #\n#   #       #       #       #       #       #       #\n#   #   #   #   #   #   #   #   #   #   #   #   #   #\n#   #   #   #   #   #   #   #   #   #   #   #   #   #\n#   #   #   #   #   #   #   #   #   #   #   #   #   #\n#   #   #   #   #   #   #   #   #   #   #   #   #   #\n#   #   #   #   #   #   #   #   #   #   #   #   #   #\n#   #   #   #   #   #   #   #   #   #   #   #   #   #\n#   #   #   #   #   #   #   #   #   #   #   #   #   #\n#   #   #   #   #   #   #   #   #   #   #   #   #   #\n#   #   #   #   #   #   #   #   #   #   #   #   #   #\n#   #   #   #   #   #   #   #   #   #   #   #   #   #\n#   #   #   #   #   #   #   #   #   #   #   #   #   #\n#   #   #   #   #   #   #   #   #   #   #   #   #   #\n#   #   #   #   #   #   #   #   #   #   #   #   #   #\n#   #   #   #   #   #   #   #   #   #   #   #   #   #\n#   #   #   #   #   #   #   #   #   #   #   #   #   #\n#   #   #   #   #   #   #   #   #   #   #   #   #   #\n#   #   #   #   #   #   #   #   #   #   #   #   #   #\n#       #       #       #       #       #       #   #\n#       #       #       #       #       #       #   #\n#################################################===#\n                                      FINISH! YOU ARE A WINNER\n\n\n\nsecret stage @ shhh", 363 )


levels =
    [ level1, level2, level3, level4, ascii ]



-- TODO abstract;conventional entry and exit points


nextlevel model =
    case model.levels of
        lvl :: rest ->
            { model
                | world = world lvl
                , point = start lvl
                , levels = rest
            }

        [] ->
            model



-- TODO implement file read or macro }}}
-- Sound {{{
-- }}}
-- Operators as a resource: stockpiles {{{


stock : Dict String Int
stock =
    Dict.fromList
        [ ( "h", 80 )
        , ( "j", 80 )
        , ( "k", 80 )
        , ( "l", 80 )
        , ( "^", 0 )
        , ( "$", 0 )
        , ( "%", 0 )
        ]


getStock : String -> Model -> Int
getStock char model =
    case Dict.get char model.stock of
        Just a ->
            a

        Nothing ->
            0


showStock : Model -> String
showStock model =
    Dict.foldl (\key val accum -> "\n" ++ key ++ " : " ++ String.fromInt val ++ accum) "" model.stock


decrementStock : String -> Model -> Model
decrementStock char model =
    { model
        | stock =
            Dict.update char
                (\x ->
                    case x of
                        Just a ->
                            Just (a - 1)

                        Nothing ->
                            Nothing
                )
                model.stock
    }


incrementStock : String -> Model -> Model
incrementStock char model =
    { model
        | stock =
            Dict.update char
                (\x ->
                    case x of
                        Just a ->
                            Just (a + 10)

                        Nothing ->
                            Nothing
                )
                model.stock
    }



-- If insufficient stock of char, return identity operator, otherwise decrement stock and return operator


consume : String -> Operator -> Operator
consume char op =
    \model ->
        if getStock char model > 0 then
            op (decrementStock char model)

        else
            model


collect : Model -> Model
collect model =
    case scan model 0 of
        "h" ->
            incrementStock "h" model |> replaceChar " "

        "j" ->
            incrementStock "j" model |> replaceChar " "

        "k" ->
            incrementStock "k" model |> replaceChar " "

        "l" ->
            incrementStock "l" model |> replaceChar " "

        "^" ->
            incrementStock "^" model |> replaceChar " "

        "$" ->
            incrementStock "$" model |> replaceChar " "

        "%" ->
            incrementStock "%" model |> replaceChar " "

        "@" ->
            nextlevel model

        _ ->
            model


decrementScore : Int -> Model -> Model
decrementScore n model =
    if model.score > 0 then
        { model | score = model.score - n }

    else
        model



-- TODO }}}
-- Game Initialization {{{


init : ( Model, Cmd Msg )
init =
    ( { world = world level0
      , point = start level0
      , numprefix = 0
      , score = 10
      , stock = stock
      , levels = levels
      , level = 0
      }
    , Cmd.none
    )



--- }}}
-- Controller: Update via messages optained from input  {{{


type Msg
    = KeyPress String


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        KeyPress code ->
            case code of
                "h" ->
                    ( consume code (prefixCompose (column Backward)) model |> collect, Cmd.none )

                "l" ->
                    ( consume code (prefixCompose (column Forward)) model |> collect, Cmd.none )

                "k" ->
                    ( consume code (prefixCompose upward) model |> collect, Cmd.none )

                "j" ->
                    ( consume code (prefixCompose downward) model |> collect, Cmd.none )

                "^" ->
                    ( consume code (prefixCompose (lineEnd Backward)) model |> collect, Cmd.none )

                "$" ->
                    ( consume code (prefixCompose (lineEnd Forward)) model |> collect, Cmd.none )

                "%" ->
                    ( consume code (prefixCompose jumpmatch) model |> collect, Cmd.none )

                "0" ->
                    ( pushNumericPrefix 0 model, Cmd.none )

                "1" ->
                    ( pushNumericPrefix 1 model, Cmd.none )

                "2" ->
                    ( pushNumericPrefix 2 model, Cmd.none )

                "3" ->
                    ( pushNumericPrefix 3 model, Cmd.none )

                "4" ->
                    ( pushNumericPrefix 4 model, Cmd.none )

                "5" ->
                    ( pushNumericPrefix 5 model, Cmd.none )

                "6" ->
                    ( pushNumericPrefix 6 model, Cmd.none )

                "7" ->
                    ( pushNumericPrefix 7 model, Cmd.none )

                "8" ->
                    ( pushNumericPrefix 8 model, Cmd.none )

                "9" ->
                    ( pushNumericPrefix 9 model, Cmd.none )

                "]" ->
                    ( nextlevel model, Cmd.none )

                _ ->
                    ( { model | score = model.score - 1 }, Cmd.none )


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ Events.onKeyPress (Decode.map KeyPress keyDecoder)
        ]


keyDecoder : Decode.Decoder String
keyDecoder =
    Decode.field "key" Decode.string



-- }}}
-- Runtime Loop: View function and UI listeners {{{


view : Model -> Html Msg
view model =
    div
        [ style "white-space" "pre-wrap"
        , style "font-family" "unifont, monospace"
        ]
        [ text (String.slice 0 model.point model.world)
        , span [ style "background-color" "fuchsia" ]
            [ text (String.slice model.point (model.point + 1) model.world) ]
        , text (String.dropLeft (model.point + 1) model.world)

        --, div [] -- TODO for testing, can clean up UI later
        --      [ text (String.fromInt model.numprefix) ]
        , div [ style "font-size" "80%" ] [ text ("Stock: " ++ showStock model) ]
        ]



-- }}}
-- vim:foldmethod=marker:foldlevel=0
