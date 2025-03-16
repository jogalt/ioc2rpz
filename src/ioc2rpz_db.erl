% Copyright 2017-2021 Vadim Pavlov
% Licensed under the Apache License, Version 2.0

-module(ioc2rpz_db).
-include_lib("ioc2rpz.hrl").

%% Export functions
-export([
    init_db/3, db_table_info/2, read_db_pkt/1, write_db_pkt/2, delete_db_pkt/1, 
    read_db_record/3, write_db_record/3, delete_old_db_record/1, saveZones/0, 
    loadZones/0, loadZones/1, get_zone_info/2, clean_DB/1, save_zone_info/1, 
    get_allzones_info/1, lookup_db_record/2
]).

%% Define the records used in ETS/Mnesia
-record(rpz_axfr_table, {zone, zone_str, serial, soa_timers, cache, wildcards, sources, ioc_md5, update_time, ioc_count, rule_count}).
-record(rpz_ixfr_table, {zone, zone_str, serial, serial_ixfr, ixfr_update_time, ixfr_nz_update_time}).

%%% ===================
%%% Database Initialization
%%% ===================

init_db(ets, DBDir, PID) ->
    [{STA, _}, {STI, _}] = loadZones(DBDir),

    if STA /= ok ->
        ets:new(rpz_axfr_table, [{heir, PID, []}, {read_concurrency, true}, {write_concurrency, true}, ordered_set, public, named_table]);
       true -> ets:give_away(rpz_axfr_table, PID, [])
    end,

    if STI /= ok ->
        ets:new(rpz_ixfr_table, [{heir, PID, []}, {read_concurrency, true}, {write_concurrency, true}, duplicate_bag, public, named_table]);
       true -> ets:give_away(rpz_ixfr_table, PID, [])
    end,

    ets:new(cfg_table, [{heir, PID, []}, {read_concurrency, true}, {write_concurrency, true}, ordered_set, public, named_table]),
    ets:new(rpz_hotcache_table, [{heir, PID, []}, {read_concurrency, true}, {write_concurrency, true}, ordered_set, public, named_table]),
    ets:new(stat_table, [{heir, PID, []}, {read_concurrency, true}, {write_concurrency, true}, ordered_set, public, named_table]),
    {ok, []}.

init_db(mnesia, _DBDir, _PID) ->
    mnesia:start(),
    case mnesia:table_info(rpz_axfr_table, size) of
        undefined -> 
            mnesia:create_table(rpz_axfr_table, [{type, set}, {attributes, record_info(fields, rpz_axfr_table)}]),
            mnesia:create_table(rpz_ixfr_table, [{type, duplicate_bag}, {attributes, record_info(fields, rpz_ixfr_table)}]);
        _ -> ok
    end,
    {ok, []}.

%%% ===================
%%% Database Reads & Writes
%%% ===================

db_table_info(Table, Param) ->
    db_table_info(?DBStorage, Table, Param).
db_table_info(ets, Table, Param) ->
    ets:info(Table, Param);
db_table_info(mnesia, Table, Param) ->
    mnesia:table_info(Table, Param).

read_db_pkt(Zone) ->
    read_db_pkt(?DBStorage, Zone).
read_db_pkt(ets, Zone) ->
    Pkt = ets:match(rpz_axfr_table, {{rpz, Zone#rpz.zone, Zone#rpz.serial, '_', '_'}, '$2'}),
    [binary_to_term(X) || [X] <- Pkt];
read_db_pkt(mnesia, _Zone) ->
    ok.

write_db_pkt(Zone, Pkt) ->
    write_db_pkt(?DBStorage, Zone, Pkt).
write_db_pkt(ets, Zone, {PktN, _, _, _, _} = Pkt) ->
    ets:insert(rpz_axfr_table, {{rpz, Zone#rpz.zone, Zone#rpz.serial, PktN, self()}, term_to_binary(Pkt, [{compressed, ?Compression}])});
write_db_pkt(mnesia, _Zone, _Pkt) ->
    ok.

delete_db_pkt(Zone) ->
    delete_db_pkt(?DBStorage, Zone).
delete_db_pkt(ets, Zone) when Zone#rpz.serial == 42 ->
    ets:match_delete(rpz_axfr_table, {{rpz, Zone#rpz.zone, '_', '_', '_'}, '_'});
delete_db_pkt(ets, Zone) ->
    ets:select_delete(rpz_axfr_table, [{{{rpz, Zone#rpz.zone, Zone#rpz.serial, '$1', '_'}, '_'}, [{'=<', '$1', Zone#rpz.serial}], [true]}]);
delete_db_pkt(mnesia, _Zone) ->
    ok.

read_db_record(Zone, Serial, Type) ->
    read_db_record(?DBStorage, Zone, Serial, Type).
read_db_record(ets, Zone, Serial, new) ->
    ets:select(rpz_ixfr_table, [
        {{{ioc, Zone#rpz.zone, '$1', '$4'}, '$2', '$3'}, [{'>', '$2', Serial}], ['$$']},
        {{{ioc, Zone#rpz.zone, '$1', '$4'}, '$2', '$3'}, [{'==', '$3', 0}], ['$$']}
    ]);
read_db_record(mnesia, _Zone, _Serial, new) ->
    ok.

write_db_record(Zone, IOC, XFR) when Zone#rpz.cache == <<"true">> ->
    write_db_record(?DBStorage, Zone, IOC, XFR);
write_db_record(_Zone, _IOC, _XFR) ->
    {ok, 0}.

get_zone_info(Zone, DB) ->
    get_zone_info(?DBStorage, Zone, DB).
get_zone_info(ets, Zone, axfr) ->
    ets:match(rpz_axfr_table, {{axfr_rpz_cfg, Zone#rpz.zone}, '$0', '$1', '$2', '$3', '$4', '$5', '$6', '$7', '$8', '$9'});
get_zone_info(mnesia, _Zone, axfr) ->
    ok.

get_allzones_info(DB) ->
    get_allzones_info(?DBStorage, DB).
get_allzones_info(ets, axfr) ->
    ets:match(rpz_axfr_table, {{axfr_rpz_cfg, '$0'}, '$1', '$2', '$3', '$4', '$5', '$6', '$7', '$8', '$9', '$10'});
get_allzones_info(mnesia, axfr) ->
    ok.

clean_DB(RPZ) ->
    AXFR = get_allzones_info(ets, axfr),
    [{delete_db_pkt(#rpz{zone = X, zone_str = Y, serial = 42}), delete_old_db_record(#rpz{zone = X, zone_str = Y, serial = 42})} || [X, Y | _] <- AXFR, lists:member(X, RPZ)],
    ok.

delete_old_db_record(Zone) ->
    delete_old_db_record(?DBStorage, Zone).
delete_old_db_record(ets, Zone) ->
    ets:select_delete(rpz_ixfr_table, [{{{ioc, Zone#rpz.zone, '_', '_'}, '$1', '_'}, [{'=<', '$1', Zone#rpz.serial}], [true]}]);
delete_old_db_record(mnesia, _Zone) ->
    ok.

lookup_db_record(IOC, Recurs) ->
    lookup_db_record(?DBStorage, IOC, Recurs).
lookup_db_record(ets, IOC, false) ->
    {ok, [{IOC, ets:select(rpz_ixfr_table, [{{{ioc, '_', IOC, '_'}, '$2', '$3'}, [], [{{'$0', '$2', '$3'}}]}])}]};
lookup_db_record(mnesia, _IOC, _Recurs) ->
    {ok, []}.
