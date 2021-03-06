%% -------------------------------------------------------------------
%%
%% erlang_cep: A Complex Event Processing Library in erlang
%%
%% Copyright (c) 2013 Daniel Macklin.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(match_engine).

%%
%% Include files
%%

-include("window.hrl").

-ifdef(TEST).
	-include_lib("eunit/include/eunit.hrl").
-endif.

%%
%% Exported Functions
%%
-export([do_match/6, run_reduce_function/7]).

%%
%% API Functions Note this only gets called after an initial first pass match.
%%

do_match(false, Matches, _Joins, _ResultsDict, _State, _Position) ->
	Matches;

%% If the Number of Matches = 0 then don't perform matches.
do_match(_First, Matches, _Joins, _ResultsDict, _State=#state{queryParameters = {0, _WindowSize, _WindowType, _Consecutive, _MatchType, _RestartStrategy}}, _Position) ->
	Matches;

do_match(true, Matches, Joins, ResultsDict, State, Position) ->
	{NumberOfMatches, WindowSize, WindowType, Consecutive, MatchType, RestartStrategy} = State#state.queryParameters,

	case MatchType of 
		matchRecognise ->
			MutatedMatchList = is_match_recognise(ResultsDict, Position, State#state.jsPort, Matches, Consecutive, RestartStrategy, State#state.parameters, Joins, State#state.rowQuery),
			run_reduce_function(State#state.pidList, MutatedMatchList, NumberOfMatches, ResultsDict, State#state.jsPort, RestartStrategy, State#state.reduceQuery);
		standard ->
			MutatedMatchList = is_match(Matches, NumberOfMatches, WindowSize, Consecutive, WindowType),
			run_reduce_function(State#state.pidList, MutatedMatchList, NumberOfMatches, ResultsDict, State#state.jsPort, RestartStrategy, State#state.reduceQuery);
		every ->
			%% Do not need to run a reduce function for an every window.  Run on the window roll-over
			Matches
	end.

run_reduce_function(_PidList, [], _NumberOfMatches, _ResultsDict, _JSPort, _RestartStrategy, _ReduceQuery) ->
	[[]];

run_reduce_function(PidList, MatchList, NumberOfMatches, ResultsDict, JSPort, RestartStrategy, ReduceQuery) ->
	Res = lists:reverse(lists:foldl(fun(Matches, Acc) -> 
											handle_reduce(Matches, Acc, NumberOfMatches, ResultsDict, ReduceQuery, JSPort, PidList, RestartStrategy)
									end,[], MatchList)),
	case Res of
		[] ->
			[[]];
		_ ->
			Res
	end.

handle_reduce(Matches, Acc, NumberOfMatches, ResultsDict, ReduceQuery, JSPort, PidList, RestartStrategy) when length(Matches) >= NumberOfMatches ->
	{ok, ReduceResults} = window_api:run_reduce_query(JSPort, [extract_results(Matches, ResultsDict)], ReduceQuery),
	bang_processes(PidList, ReduceResults),
								
	case RestartStrategy of
		restart ->
			Acc;
		noRestart ->
		   [Matches] ++ Acc
	end;

handle_reduce(Matches, Acc, _NumberOfMatches, _ResultsDict, _ReduceQuery, _JSPort, _PidList, _RestartStrategy) ->
	[Matches] ++ Acc.
	
%% @doc Bang a message to the processes that have registered an interest in this window
bang_processes(ProcessList, Results) ->
	lists:foreach(fun(Pid) ->
					Pid ! Results
				  end, ProcessList).

%% @doc Extract the Matches from the results dictionary.  The results dict stores {Row, Result}
extract_results(MatchList, ResultsDict) ->	
	lists:reverse(lists:foldl(fun(Match, Acc) ->		  
					{_Row, Result} = dict:fetch(Match, ResultsDict),
					[Result | Acc]
				end, [], MatchList)).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% @doc Run a Match Recognise
%% 		Return a list, containing a list of positions where the Match Recognise row function returns true.
%% 		For example [[R1,R2,R3], [R2,R3,R4]]
%% 		For consecutive matches the rows have to match in order i.e. 1,2,3.

%% 		When we run a row function and the basic query is matched
%% 		we then need to re-run the query against the last match for all the other matches
%% 		as they might also match the row function.

%% 		If the match recognise row function returns true, we add the row position to the match list.
%% 		If the match recognise row function returns false, then
%% 		for consecutive queries delete the row from the math dictionary. For nonConsecutive carry on.

%% 		If size of the match dict >= Number Of matches then fire.

%% 		The function mutates the Match Dictionary. 

%% 		Thought process for non consecutive

%% 		R1 Matches its initial first pass match --> 
%% 		ResultsDictionary Key [R1], MatchList = [R1] --> The match_recognise_row_function will return straight away as R1 is already in the match list
%% 		R2 Matches it's initial first pass match -->
%% 		ResultsDictionary Key [R1], match_recognise_row_function will run and return true -->  MatchList = [R1, R2]
%% 		R3 Matches it's initial first pass match -->
%% 		ResultsDictionary key [R1], MatchList = [R1,R2] --> The row function fails MatchList = [R1, R2]
%% 		R4 Matches it's initial first pass match , MatchList = [R1, R2]  --> The match_recognise_row_function will attempt to match R4 against R2.  It Does so
%% 		MatchList = [R1, R2, R4].
%% 		The point of a nonConsecutive match_recognise is to fire when there is a progression of a certain size (even if the odd one does not match)
%% 		The point of a consecutive match_recognise is to to fire when there is a consecutive progression of values.

%% 		Therefore this function returns a tuple {NewMatchDictionary, MatchList}

%% 		The Match list just contains this position.  This should only happen when some data has passed the first part of the matchRecognise row function
%% 		Where previously the match list was empty

%% 		An empty match list must return an empty match list.
%%	@end
is_match_recognise(_ResultsDict, _Position, _JSPort, [[]], consecutive, _RestartStrategy, _Parameters, _Joins, _RowQuery) ->
	[[]];

is_match_recognise(_ResultsDict, Position, _JSPort, [[Position]] = Matches, consecutive, _RestartStrategy, _Parameters, _Joins, _RowQuery) ->
	Matches;

is_match_recognise(ResultsDict, Position, JSPort, Matches, consecutive, RestartStrategy, Parameters, Joins, RowQuery) ->
	lists:foldl(fun(Match, Acc) ->
						case run_match_recognise_row_function(ResultsDict, Position, JSPort, Match, RestartStrategy, Parameters, Joins, RowQuery) of
							[] ->
								%% Remember that although the row function has failed it has still passed it's first test!
								[[Position]] ++ Acc;
							MatchListResult ->
								[MatchListResult] ++ Acc
						end
				end,[], Matches);

%% @doc For non consecutive if there is no match add a new match element to the match list.
%% 		i.e. Before [[1,2,3]] 4 doesn't match so we have [[1,2,3], [4]] 
%% @end
is_match_recognise(ResultsDict, Position, JSPort, Matches, nonConsecutive, RestartStrategy, Parameters, Joins, RowQuery) ->
	lists:foldl(fun(Match, Acc) ->
						do_match_recognise_nonConsecutive(ResultsDict, Position, JSPort, Match, RestartStrategy, Acc, Parameters, Joins, RowQuery)
				end,[], Matches).

%% Only one element in MatchList for this position so return match
do_match_recognise_nonConsecutive(_ResultsDict, Position, _JSPort, [Position] = Match, _RestartStrategy, _Acc, _Parameters, _Joins, _RowQuery) ->
	[Match];

do_match_recognise_nonConsecutive(ResultsDict, Position, JSPort, Match, RestartStrategy, Acc, Parameters, Joins, RowQuery) ->
	case run_match_recognise_row_function(ResultsDict, Position, JSPort, Match, RestartStrategy, Parameters, Joins, RowQuery) of
		[] ->
			%% Remember that although the row function has failed it has still passed the first test!
			[[Position]] ++ [Match] ++ Acc;
		MatchListResult ->
			[MatchListResult] ++ Acc
	end.

run_match_recognise_row_function(_ResultsDict, _Position, _JSPort, [] , _RestartStrategy, _Parameters, _Joins, _RowQuery) ->
	[];

run_match_recognise_row_function(ResultsDict, Position, JSPort, Match, _RestartStrategy, Parameters, Join, RowQuery) ->
	%% run the match recognise row function on the last element of the MatchList.  
    %% When running second matches the Matched Data is an array [goog, price.......
	
	{NewRow, _Result} = dict:fetch(Position, ResultsDict),
		
	{MatchedRow, _MatchedResult} = dict:fetch(get_last(Match), ResultsDict),
			
	case window_api:run_row_query(Parameters, Join, JSPort, NewRow, MatchedRow, Match, RowQuery) of
		{ok, false} ->
					[];
					
		{ok, true} ->
					lists:append(Match, [Position])
	end.

%% @doc Get the last element in the match list.  As this is the one that we want to run the row function on.
get_last([Element]) ->
	Element;
get_last(MatchList) ->
	[ LastMatch | _ ] = lists:reverse(MatchList),
	LastMatch.

%% @doc The standard consecutive match, with a noRestart strategy,  which means that if
%% 		we get a match do not clear down the match dictionary.
%% 		Return a list of the matching row positions if there is a match,
%% 		Or an empty list for no matches  
%% 		standard means no match recognise
%% 		Restart strategy is what we do once a match is found.  
%%
%% 		Complex case where matches have to be consecutive [[1,2,3], [3,4,5]]
%% @end
is_match(Matches, NumberOfMatches, WindowSize, consecutive, WindowType) ->
	lists:foldl(fun(Match, Acc) ->
						%%io:format("Match = ~p ~n", [Match]),
						case is_consecutive(Match, start, [], WindowSize, NumberOfMatches, WindowType) of
							[] ->
								Acc;
							ConsecutiveMatch ->
								Acc ++ [ConsecutiveMatch]
						end
				end,[],Matches);

%% @doc Case where matches do not need to be consecutive
is_match(Matches, _NumberOfMatches, _WindowSize, nonConsecutive, _WindowType) ->
	Matches.

is_consecutive([H | T], start, [], WindowSize, NumberOfMatches, WindowType) ->
	lists:reverse(is_consecutive(T, H, [], WindowSize, NumberOfMatches, WindowType));

is_consecutive([], start, _Matches, _WindowSize, _NumberOfMatches, _WindowType) ->
	[];

%% @doc We've gone through all the available matches
is_consecutive([], LastHead, Matches, _WindowSize, _NumberOfMatches, _WindowType) ->
	[LastHead | Matches];

is_consecutive([H | T], LastHead, Matches, WindowSize, NumberOfMatches, WindowType) ->
	case window_api:next_position(LastHead, WindowSize, WindowType) == H of
		true ->
			is_consecutive(T, H, [LastHead | Matches], WindowSize, NumberOfMatches, WindowType);
		false ->
			[]
	end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% These are our tests
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-ifdef(TEST).

%% @doc Test to see if the elements in a list are consecutive.
%% 		Should return the list if they are, should return an empty
%% 		list if not.
%% @end

is_consecutive_nothing_test() ->
	?assertEqual([],  is_consecutive([], start, [], 0, 0, size)).

is_consecutive_pass_test() ->
	?assertEqual([0,1,2,3,4,5],  is_consecutive([0,1,2,3,4,5], start, [], 0, 0, size)).

is_consecutive_pass_time_test() ->
	?assertEqual([0,1,2,3,4,5],  is_consecutive([0,1,2,3,4,5], start, [], 0, 0, time)).

is_consecutive_fail_test() ->
	?assertEqual([],  is_consecutive([0,1,2,3,4,5,2], start, [], 0, 0, size)).

%% @doc Given Looking for a Match of 5 consecutive elements [[1,2,3,4,5]] using a standard match
is_match_consecutive_standard_test() ->
	?assertEqual([[0,1,2,3,4,5]], is_match([[0,1,2,3,4,5]], 10, 10, consecutive, size)).

is_match_consecutive_standard_multiple_test() ->
	?assertEqual([[0,1,2,3,4,5], [2,3,4,5]], is_match([[0,1,2,3,4,5], [2,3,4,5]], 10, 10, consecutive, size)).

%% @doc There are two matches here, one should pass, the other fail
is_match_consecutive_standard_multiple_one_fail_test() ->
	?assertEqual([[0,1,2,3,4,5]], is_match([[0,1,2,3,4,5], [2,3,5]], 10, 10, consecutive, size)).

%% @doc There are two matches here, one should pass, the other fail
is_match_nonConsecutive_standard_multiple_one_fail_test() ->
	?assertEqual([[0,1,3]], is_match([[0,1,3]], 10, 10, nonConsecutive, size)).

is_match_consecutive_fail_test() ->
	?assertEqual([], is_match([[0,1,3,5]], 10, 10, consecutive, size)).

-endif.