-module(logger).
-behaviour(gen_server).
-export([logging_is_on/0,
	 log_action/4,
	 start_link/0,
	 end_current_log/0]).
-export([init/1,handle_cast/2,terminate/2,code_change/3,
	 handle_call/3,handle_info/2]).
-ifdef(TEST).
-ifdef(TODO_FIX_TESTS).
-export([correct_content_test/0,
	 correct_no_files_test/0,
	 duration_works_test/0]).
-endif.
-endif.

%TODO ask whether use of now() is suitable
%TODO put records in suitable header
-record(logger_state,{end_log_ref = no_ref :: reference() | atom(),
		      log=no_log :: atom(),
		      hash_key, %undefined means no hashing
		      is_logging=false :: boolean()}).
-record(oplog_on_request,{size :: pos_integer(),
			  duration :: non_neg_integer() | infinity,
                          salt}).
-record(log_entry,{timestamp  = now(),
		   bucket,
		   key,
		   action :: write | read | delete,
		   index_vals :: {any(),any()} | {},
		   val_size :: non_neg_integer(),
		   compressibility :: pos_integer()
		  }).


%1 GB
-define(DEFAULT_LOG_SIZE,(1024*1024*1024)).
%relative path to the log folder
-define(LOG_PATH,"log/").

%An exception in lookup should mean that the logger_state_ets doesn't
%yet exist. That should only be the case for a short time after
%logger start or restart.
-spec logging_is_on()-> boolean().
logging_is_on()->catch(ets:lookup(logger_state_ets,is_logging))
		     ==[{is_logging,true}].
-spec set_logging_is_on(boolean())-> ok.
set_logging_is_on(Bool)->
    try ets:insert(logger_state_ets,{is_logging,Bool}) of
	_ -> ok
    catch 
	_ -> ets:new(logger_state_ets,[named_table,public]),
	     ets:insert(logger_state_ets,{is_logging,Bool})
    end.


log_action(Bucket,Key,Action,Index_vals)->
    log(#log_entry{
	   bucket = Bucket,
	   key = Key,
	   action = Action,
	   index_vals = Index_vals
	  }).

%this is the basic logging function.
%all other logging functions should call this
-spec log(any())-> ok.
log(Term)->
    case logging_is_on() of
	true -> 
	    gen_server:cast(logger,{log,Term});
	false ->
	    ok
    end.

%This is a bit of a hack, should I add a new oplog_off request?
-spec end_current_log()-> ok.
end_current_log()->
    gen_server:cast(logger,#oplog_on_request{duration=0}).

%Each node has a log, so it doesn't need to be in distributed mode
%Is logger too generic a name for the module & process?
-spec init(any())-> {ok,#logger_state{}}.
init(_) ->
    self() ! make_a_new_ets,
    {ok,#logger_state{}}.

%Opens a new log in response to oplog on <args>
%First call to oplog on opens new log, even w/o args
%Log name internal to genserver.
%Does not take salt as argument for now.
-spec new_log(pos_integer())-> atom().
new_log(Size)->
    Time = now(), %not too important exactly when it was opened?
    Node = node(),
    [disk_log:close(logger_log) || disk_log:info(logger_log) /=
				       {error,no_such_log}],
    {ok,Log} = disk_log:open([
			      {name,logger_log},
			      {file,?LOG_PATH ++ 
				   lists:flatten(io_lib:format(
						   "logger_log~p~p.log",
						   [Node,Time]))},
			      {type,halt},
			      {format,internal},
			      {mode,read_write},
			      {size,Size},
			      {linkto,self()}
			     ]),
    Log.

-spec disk_log(atom(),term())->ok.
disk_log(Log,Term)-> ok = disk_log:log(Log,Term).

%logger will likely crash upon log filling up, will supervisor manage that?
-spec handle_cast(oplog_on | #oplog_on_request{} | oplog_off | {log,term()},
                  #logger_state{})->
			 {noreply,#logger_state{}}.
handle_cast(oplog_on,State)->
    set_logging_is_on(true),
    {noreply,State#logger_state{is_logging=true,
				log=case State#logger_state.log of
					no_log -> 
					    new_log(?DEFAULT_LOG_SIZE);
					L -> L end}};
handle_cast(#oplog_on_request{size=Size,duration=Duration},State)->
    set_logging_is_on(true),
    case State#logger_state.log of
	no_log -> ok;
	L -> disk_log:close(L)
    end,
    {noreply,
     case Duration > 0 of
	 false ->
	     #logger_state{};
	 true ->  
	     #logger_state{
		end_log_ref =
		    case Duration of 
			infinity -> no_ref;
			_ -> Log_Id = make_ref(),
			     erlang:send_after(Duration,self(),
					       {scheduled_log_end,Log_Id}),
			     Log_Id
		    end,
		log = new_log(Size),
		is_logging = true
	       }
     end};
handle_cast(oplog_off,State)->
    case set_logging_is_on(false) of
	ok -> {noreply,State#logger_state{is_logging=false}};
	error -> gen_server:cast(logger,oplog_off)
    end;
handle_cast({log,Term},State = #logger_state{
				  log=L,
				  is_logging=IL})->
    {noreply,
     case IL of
	 false -> State;
	 true -> 
	     disk_log(L,Term),
	     State
     end}.

terminate(_Reason,#logger_state{})->
    ok. %disk log should close automatically here

-spec code_change(term(),#logger_state{},term())->{ok,#logger_state{}}.
code_change(_OldVsn,State,_Extra)->{ok,State}.
-spec handle_call(term(),term(),#logger_state{})->{noreply,#logger_state{}}.
handle_call(_Req,_From,State)->{noreply,State}.
-spec handle_info(term(),#logger_state{})-> {noreply,#logger_state{}}.
handle_info({scheduled_log_end,Log_Id},
	    State = #logger_state{end_log_ref=LID,log=L})->
    {noreply,
     case Log_Id == LID of
	 true -> disk_log:close(L),
		 #logger_state{};
	 false -> State
     end};
handle_info(make_a_new_ets,State)-> 
    ets:new(logger_state_ets,[named_table]),
    ok = set_logging_is_on(false),
    {noreply,State};
handle_info(_Info,State)->{noreply,State}.

-spec start_link() -> ignore | {error,term()} | {ok,pid()}.
start_link()->
    gen_server:start_link({local,logger},logger,no_args,[]).

%TODO: Rewrite tests (I've changed log/1 to check logger_state_ets to see 
%whether it shld run, which means that the ets causes a lag between turning
%logging on/off & log/1 recognizing that). 
-ifdef(TEST).

-ifdef(TODO_FIX_TESTS).
-spec start()-> ignore | {error,term()} | {ok,pid()}.
start()->
    gen_server:start(logger,no_args,[]).
correct_content_test()-> 
    start(),
    gen_server:cast(logger,oplog_on),
    log(alice),
    log(bob),
    gen_server:cast(logger,oplog_off),
    log(charles),
    timer:sleep(100),
    {{continuation,_,_,_},Log_Contents} = disk_log:chunk(logger_log,start),
    Log_Contents == [alice,bob] .

correct_no_files_test()->
    start(),
    ForeachFile = fun(F) -> 
			  {ok,Files} = file:list_dir_all(?LOG_PATH),
			  lists:map(F,Files)
		  end,
    ForeachFile(fun(File)->ok = file:rename(?LOG_PATH++File,
					    ?LOG_PATH++"OLD"++File) 
		    end),
    gen_server:cast(logger,oplog_on),
    end_current_log(),
    gen_server:cast(logger,oplog_on),
    end_current_log(),
    gen_server:cast(logger,oplog_on),
    end_current_log(),
    timer:sleep(100),
    length(lists:filter(fun(X)->X end,
			ForeachFile(fun(File) -> 
					    case File of
						"OLD" ++ File2 ->
						    file:rename(?LOG_PATH++File,
								?LOG_PATH++
								    File2),
						    false;
						_ -> ok = file:delete(?LOG_PATH
								      ++File),
						     true
					    end
				    end)
		       )
	  )==3.
			  

duration_works_test()->
    start(),
    gen_server:cast(logger,#oplog_on_request{size = ?DEFAULT_LOG_SIZE,
					     duration=1}),
    timer:sleep(1000),
    eof=disk_log:chunk(logger_log,start),
    log(value),%this should close log
    timer:sleep(100),
    {error,no_such_log} == disk_log:info(logger_log).
-endif.

-endif.
