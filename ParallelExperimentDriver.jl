########################################################################################################################
module ParallelExperimentDriver 
########################################################################################################################
# imports and exports
using Distributed
using Debugger
@everywhere push!(LOAD_PATH, "/data/gpfs/home/cgrudzien/da_benchmark")
@everywhere push!(LOAD_PATH, "/data/gpfs/home/cgrudzien/da_benchmark/methods")
@everywhere push!(LOAD_PATH, "/data/gpfs/home/cgrudzien/da_benchmark/models")
@everywhere push!(LOAD_PATH, "/data/gpfs/home/cgrudzien/da_benchmark/experiments")
@everywhere using FilterExps, SmootherExps, EnsembleKalmanSchemes, DeSolvers, L96, JLD, ParallelExperimentDriver
@everywhere export wrap_exp

########################################################################################################################
########################################################################################################################
## Timeseries data 
########################################################################################################################
# observation timeseries to load into the experiment as truth twin
# timeseries are named by the model, seed to initialize, the integration scheme used to produce, number of analyses,
# the spinup length, and the time length between observation points
#
time_series_1 = "./data/time_series/l96_time_series_seed_0000_dim_40_diff_0.00_tanl_0.05_nanl_50000_spin_5000_h_0.010.jld"
time_series_2 = "./data/time_series/l96_time_series_seed_0000_dim_40_diff_0.00_tanl_0.10_nanl_50000_spin_5000_h_0.010.jld"
#time_series = "./data/timeseries/l96_timeseries_seed_0000_dim_40_diff_0.10_tanl_0.05_nanl_50000_spin_5000_h_0.005.jld"
#time_series = "./data/timeseries/l96_timeseries_seed_0000_dim_40_diff_0.10_tanl_0.10_nanl_50000_spin_5000_h_0.005.jld"
########################################################################################################################

########################################################################################################################
## Experiment parameter generation 
########################################################################################################################
########################################################################################################################

########################################################################################################################
# Filters
########################################################################################################################
########################################################################################################################
# filter_state 
########################################################################################################################
## [time_series, scheme, seed, obs_un, obs_dim, N_ens, infl] = args
#
#schemes = ["enkf-n-primal", "enkf-n-primal-ls", "enkf-n-dual"]
#seed = 0
#obs_un = 1.0
#obs_dim = 40
#N_ens = 15:43
#infl = [1.0]#LinRange(1.0, 1.20, 21)
#
## load the experiments
#args = Tuple[]
#for scheme in schemes
#    for N in N_ens
#        for α in infl
#            tmp = (time_series, scheme, seed, obs_un, obs_dim, N, α)
#            push!(args, tmp)
#        end
#    end
#end
#
#experiment = FilterExps.filter_state
#
#
########################################################################################################################
# filter_param 
########################################################################################################################
## [time_series, scheme, seed, obs_un, obs_dim, param_err, param_wlk, N_ens, state_infl, param_infl] = args
#
#schemes = ["enkf", "etkf"]
#seed = 0
#obs_un = 1.0
#obs_dim = 40
#param_err = 0.03
#param_wlk = [0.0000, 0.0001, 0.0010, 0.0100]
#N_ens = 14:41
#state_infl = LinRange(1.0, 1.20, 21)
#param_infl = LinRange(1.0, 1.00, 1)
#
## load the experiments
#args = Tuple[]
#for scheme in schemes
#    for wlk in param_wlk
#        for N in N_ens
#            for s_infl in state_infl
#                for p_infl in param_infl
#                    tmp = (time_series, scheme, seed, obs_un, obs_dim, param_err, wlk, N, s_infl, p_infl)
#                    push!(args, tmp)
#                end
#            end
#        end
#    end
#end
#
#experiment = FilterExps.filter_param
#
#
########################################################################################################################
########################################################################################################################
# Classic smoothers
########################################################################################################################
## classic_state parallel run, arguments are
## time_series, method, seed, lag, shift, obs_un, obs_dim, γ, N_ens, state_infl = args
#
schemes = ["mles-n-transform"]
seed = 0
lag = 1:3:52
gammas = Array{Float64}(1:11)
shift = 1
obs_un = 1.0
obs_dim = 40
#N_ens = 15:2:41
N_ens = [21]
state_infl = [1.0]
#state_infl = LinRange(1.0, 1.10, 11)
time_series = [time_series_2]

# load the experiments
args = Tuple[]
for ts in time_series
    for scheme in schemes
        for γ in gammas
            for l in lag
                for N in N_ens
                    for s_infl in state_infl
                        tmp = (ts, scheme, seed, l, shift, obs_un, obs_dim, γ, N, s_infl)
                        push!(args, tmp)
                    end
                end
            end
        end
    end
end


# define the robust to failure wrapper
function wrap_exp(arguments)
    try
        classic_state(arguments)
    catch
        print("Error on " * string(args) * "\n")
    end
end

experiment = wrap_exp


########################################################################################################################
## classic_param single run for debugging, arguments are
##  [time_series, method, seed, lag, shift, obs_un, obs_dim, param_err, param_wlk, N_ens, state_infl, param_infl = args
#
#schemes = ["enks", "etks"]
#seed = 0
#lag = 1:5:51
#shift = 1
#obs_un = 1.0
#obs_dim = 40
#N_ens = 14:41
#param_err = 0.03
#param_wlk = [0.0000, 0.0001, 0.0010, 0.0100]
#state_infl = LinRange(1.0, 1.20, 21)
#param_infl = LinRange(1.0, 1.00, 1)
#
## load the experiments
#args = Tuple[]
#for scheme in schemes
#    for l in lag
#        for N in N_ens
#            for wlk in param_wlk
#                for s_infl in state_infl
#                    for p_infl in param_infl
#                        tmp = (time_series, scheme, seed, l, shift, obs_un, obs_dim, param_err, wlk, N, s_infl, p_infl)
#                        push!(args, tmp)
#                    end
#                end
#            end
#        end
#    end
#end
#
#experiment = SmootherExps.classic_param
#
#
########################################################################################################################

########################################################################################################################
# Single iteration smoothers
########################################################################################################################
# single iteration single run for degbugging, arguments are
# [time_series, method, seed, lag, shift, mda, obs_un, obs_dim, N_ens, state_infl = args
#
#schemes = ["mles-n-transform"]
#seed = 0
#lag = 1:3:52
#gammas = Array{Float64}(1:11)
#shift = 1
#obs_un = 1.0
#obs_dim = 40
##N_ens = 15:2:43
#N_ens = [21]
#state_infl = [1.0]
##state_infl = LinRange(1.0, 1.10, 11)
#mdas = [false]
#time_series = [time_series_2]
#
## load the experiments
#args = Tuple[]
#for ts in time_series
#    for γ in gammas
#        for scheme in schemes
#            for l in lag
#                for N in N_ens
#                    for s_infl in state_infl
#                        for m in mdas
#                            tmp = (ts, scheme, seed, l, shift, m, obs_un, obs_dim, γ, N, s_infl)
#                            push!(args, tmp)
#                        end
#                    end
#                end
#            end
#        end
#    end
#end
#
#experiment = SmootherExps.single_iteration_state
#
########################################################################################################################
# hybrid_param single run for debugging, arguments are
# time_series, method, seed, lag, shift, mda, obs_un, obs_dim, param_err, param_wlk, N_ens, state_infl, param_infl = args
#
#schemes = ["etks"]
#seed = 0
#lag = 1:5:51
#shift = 1
#obs_un = 1.0
#obs_dim = 40
#N_ens = 15:2:43
#param_err = 0.03
#param_wlk = [0.0000, 0.0001, 0.0010, 0.0100]
#state_infl = LinRange(1.0, 1.10, 11)
#param_infl = LinRange(1.0, 1.00, 1)
#mda = [true, false]
#
## load the experiments
#args = Tuple[]
#for scheme in schemes
#    for l in lag
#        for N in N_ens
#            for s_infl in state_infl
#                for p_infl in param_infl
#                    for wlk in param_wlk
#                        for da in mda
#                            tmp = (time_series, scheme, seed, l, shift, da, obs_un, obs_dim, param_err, wlk, N, s_infl, p_infl)
#                            push!(args, tmp)
#                        end
#                    end
#                end
#            end
#        end
#    end
#end
#
#experiment = SmootherExps.hybrid_param
#
########################################################################################################################
########################################################################################################################
# Run the experiments in parallel over the parameter values
########################################################################################################################
########################################################################################################################
pmap(experiment, args)

end
