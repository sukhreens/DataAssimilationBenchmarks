########################################################################################################################
module SingleExperimentDriver 
########################################################################################################################
# imports and exports
using Random, Distributions
using Debugger
using Distributed
using LinearAlgebra
using JLD
using DeSolvers
using L96 
using EnsembleKalmanSchemes
using FilterExps
export exp

########################################################################################################################
########################################################################################################################
## Timeseries data 
########################################################################################################################
# observation timeseries to load into the experiment as truth twin
# timeseries are named by the model, seed to initialize, the integration scheme used to produce, number of analyses,
# the spinup length, and the time length between observation points
#
time_series = "./data/timeseries/l96_timeseries_seed_0000_dim_40_diff_0.00_tanl_0.05_nanl_50000_spin_5000_h_0.010.jld"
########################################################################################################################

########################################################################################################################
## Experiments to run as a single function call
########################################################################################################################

########################################################################################################################
# Filters
########################################################################################################################
# filter_state single run for degbugging, arguments are
# [time_series, scheme, seed, obs_un, obs_dim, N_ens, infl] = args
#
#args = (time_series, "enkf", 0, 1.0, 40, 25, 1.12)
#print(filter_state(args))
########################################################################################################################
## filter_param single run for degbugging, arguments are
## [time_series, scheme, seed, obs_un, obs_dim, param_err, param_wlk, N_ens, state_infl, param_infl] = args
#
args = (time_series, "enkf", 0, 1.0, 40, 0.03, 0.0010, 25, 1.12, 1.0)
filter_param(args)
########################################################################################################################

########################################################################################################################
# Classic smoothers
########################################################################################################################
## classic_state single run for degbugging, arguments are
## [time_series, method, seed, lag, shift, obs_un, obs_dim, N_ens, infl] = args
#
#args = [time_series, 'etks', 0, 11, 11, 1.0, 40, 25, 1.05]
#print(classic_state(args))
########################################################################################################################
## classic_param single run for debugging, arguments are
## [time_series, method, seed, lag, shift, obs_un, obs_dim, param_err, param_wlk, N_ens, state_infl, param_infl] = args
#
#args = [time_series, 'etks', 0, 1, 1, 1.0, 40, 0.03, 0.01, 24, 1.08, 1.0] 
#print(classic_param(args))
########################################################################################################################

########################################################################################################################
# Hybrid smoothers
########################################################################################################################
# hybrid_state single run for degbugging, arguments are
# [time_series, method, seed, lag, shift, obs_un, obs_dim, N_ens, infl] = args
#
#args = [time_series, 'etks', 0, 31, 1, 1.0, 40, 25, 1.01]
#print(hybrid_state(args))
########################################################################################################################
# hybrid_param single run for debugging, arguments are
# [time_series, method, seed, lag, shift, obs_un, obs_dim, param_err, param_wlk, N_ens, state_infl, param_infl] = args
#
#args = [time_series, 'etks', 0, 26, 1, 1.0, 40, 0.03, 0.01, 25, 1.01, 1.0] 
#print(hybrid_param(args))
########################################################################################################################

end
