##############################################################################################
module FilterExps
##############################################################################################
##############################################################################################
# imports and exports
using JLD2
using Random, Distributions, Statistics
using LinearAlgebra
using ..EnsembleKalmanSchemes, ..DeSolvers, ..L96, ..IEEE39bus
export filter_state, filter_param

##############################################################################################
##############################################################################################
# Type union declarations for multiple dispatch

# dictionaries of parameters
ParamDict = Union{Dict{String, Array{Float64}}, Dict{String, Vector{Float64}}}

##############################################################################################
##############################################################################################
# Main filtering experiments, debugged and validated for use with schemes in methods directory
##############################################################################################

function filter_state(args::Tuple{String,String,Int64,Int64,Float64,Int64,Float64,
                                  Int64,Float64})

    # time the experiment
    t1 = time()

    # Define experiment parameters
    time_series, method, seed, nanl, obs_un, obs_dim, γ, N_ens, infl = args

    # load the timeseries and associated parameters
    ts = load(time_series)::Dict{String,Any}
    diffusion = ts["diffusion"]::Float64
    dx_params = ts["dx_params"]::ParamDict
    tanl = ts["tanl"]::Float64
    model = ts["model"]::String
    
    # set the integration step size for the ensemble at 0.01 if an SDE, if deterministic
    # simply use the same step size as the observation model
    if diffusion > 0.0
        h = 0.01
    else
        h = ts["h"]
    end
    
    # define the dynamical model derivative for this experiment from the name
    # supplied in the time series
    if model == "L96"
        dx_dt = L96.dx_dt
    elseif model == "IEEE39bus"
        dx_dt = IEEE39bus.dx_dt
    end
    
    # define integration method
    step_model! = rk4_step!
    
    # number of discrete forecast steps
    f_steps = convert(Int64, tanl / h)

    # set seed 
    Random.seed!(seed)
    
    # define the initialization
    obs = ts["obs"]::Array{Float64, 2}
    init = obs[:, 1]
    sys_dim = length(init)
    ens = rand(MvNormal(init, I), N_ens)

    # define the observation range and truth reference solution
    obs = obs[:, 2:nanl + 1]
    truth = copy(obs)

    # define kwargs for the filtering method
    # and the underlying dynamical model
    kwargs = Dict{String,Any}(
                              "dx_dt" => dx_dt,
                              "f_steps" => f_steps,
                              "step_model" => step_model!, 
                              "dx_params" => dx_params,
                              "h" => h,
                              "diffusion" => diffusion,
                              "gamma" => γ,
                             )

    # define the observation operator, observation error covariance and observations
    # with error observation covariance operator taken as a uniform scaling by default,
    # can be changed in the definition below
    obs = alternating_obs_operator(obs, obs_dim, kwargs)
    obs += obs_un * rand(Normal(), size(obs))
    obs_cov = obs_un^2.0 * I
    
    # check if there is a diffusion structure matrix
    if haskey(ts, "diff_mat")
        kwargs["diff_mat"] = ts["diff_mat"]
    end
   
    # create storage for the forecast and analysis statistics
    fore_rmse = Vector{Float64}(undef, nanl)
    filt_rmse = Vector{Float64}(undef, nanl)
    
    fore_spread = Vector{Float64}(undef, nanl)
    filt_spread = Vector{Float64}(undef, nanl)

    # loop over the number of observation-forecast-analysis cycles
    for i in 1:nanl
        # for each ensemble member
        for j in 1:N_ens
            # loop over the integration steps between observations
            @views for k in 1:f_steps
                step_model!(ens[:, j], 0.0, kwargs)
                if model == "IEEE39bus"
                    # set phase angles mod 2pi
                    ens[1:10, j] .= rem2pi.(ens[1:10, j], RoundNearest)
                end
            end
        end

        # compute the forecast statistics
        fore_rmse[i], fore_spread[i] = analyze_ens(ens, truth[:, i])

        # after the forecast step, perform assimilation of the observation
        analysis = ensemble_filter(method, ens, obs[:, i], obs_cov, infl, kwargs)
        ens = analysis["ens"]

        # compute the analysis statistics
        filt_rmse[i], filt_spread[i] = analyze_ens(ens, truth[:, i])
    end

    data = Dict{String,Any}(
                            "fore_rmse" => fore_rmse,
                            "filt_rmse" => filt_rmse,
                            "fore_spread" => fore_spread,
                            "filt_spread" => filt_spread,
                            "method" => method,
                            "seed" => seed, 
                            "diffusion" => diffusion,
                            "dx_params" => dx_params,
                            "sys_dim" => sys_dim,
                            "obs_dim" => obs_dim, 
                            "obs_un" => obs_un,
                            "gamma" => γ,
                            "nanl" => nanl,
                            "tanl" => tanl,
                            "h" =>  h,
                            "N_ens" => N_ens, 
                            "state_infl" => round(infl, digits=2)
                           ) 
    
    if haskey(ts, "diff_mat")
        data["diff_mat"] = ts["diff_mat"]
    end
        
    path = joinpath(@__DIR__, "../data/", method * "/") 
    name = method * 
            "_" * model *
            "_state_seed_" * lpad(seed, 4, "0") * 
            "_diff_" * rpad(diffusion, 5, "0") * 
            "_sysD_" * lpad(sys_dim, 2, "0") * 
            "_obsD_" * lpad(obs_dim, 2, "0") * 
            "_obsU_" * rpad(obs_un, 4, "0") *
            "_gamma_" * lpad(γ, 5, "0") *
            "_nanl_" * lpad(nanl, 5, "0") * 
            "_tanl_" * rpad(tanl, 4, "0") * 
            "_h_" * rpad(h, 4, "0") *
            "_nens_" * lpad(N_ens, 3,"0") * 
            "_stateInfl_" * rpad(round(infl, digits=2), 4, "0") * 
            ".jld2"

    save(path * name, data)
    print("Runtime " * string(round((time() - t1)  / 60.0, digits=4))  * " minutes\n")
end


##############################################################################################


function filter_param(args::Tuple{String,String,Int64,Int64,Float64,Int64,Float64,Float64,
                                  Float64,Int64,Float64,Float64})
    # time the experiment
    t1 = time()

    # Define experiment parameters
    time_series, method, seed, nanl, obs_un, obs_dim, γ, param_err, param_wlk, N_ens, 
    state_infl, param_infl = args

    # load the timeseries and associated parameters
    ts = load(time_series)::Dict{String,Any}
    diffusion = ts["diffusion"]::Float64
    dx_params = ts["dx_params"]::ParamDict
    tanl = ts["tanl"]::Float64
    model = ts["model"]::String
    
    # set the integration step size for the ensemble at 0.01 if an SDE, if deterministic
    # simply use the same step size as the observation model
    if diffusion > 0.0
        h = 0.01
    else
        h = ts["h"]
    end
    
    # define the dynamical model derivative for this experiment from the name
    # supplied in the time series
    if model == "L96"
        dx_dt = L96.dx_dt
    elseif model == "IEEE39bus"
        dx_dt = IEEE39bus.dx_dt
    end
    step_model! = rk4_step!
    
    # number of discrete forecast steps
    f_steps = convert(Int64, tanl / h)

    # set seed 
    Random.seed!(seed)
    
    # define the initialization
    obs = ts["obs"]::Array{Float64, 2}
    init = obs[:, 1]
    if model == "L96"
        param_truth = pop!(dx_params, "F")
    elseif model == "IEEE39bus"
        param_truth = [pop!(dx_params, "H"); pop!(dx_params, "D")]
        param_truth = param_truth[:]
    end

    # define state and extended system dimensions
    state_dim = length(init)
    sys_dim = state_dim + length(param_truth)

    # define the initial ensemble
    ens = rand(MvNormal(init, I), N_ens)
    
    # extend this by the parameter ensemble    
    # note here the covariance is supplied such that the standard deviation is a percent
    # of the parameter value
    param_ens = rand(MvNormal(param_truth[:], diagm(param_truth[:] * param_err).^2.0), N_ens)
    
    # define the extended state ensemble
    ens = [ens; param_ens]

    # define the observation range and truth reference solution
    obs = obs[:, 2:nanl + 1]
    truth = copy(obs)
    
    # define kwargs, note the possible exclusion of dx_params if it is the only parameter for
    # dx_dt and this is the parameter to be estimated
    kwargs = Dict{String,Any}(
                              "dx_dt" => dx_dt,
                              "dx_params" => dx_params,
                              "f_steps" => f_steps,
                              "step_model" => step_model!,
                              "h" => h,
                              "diffusion" => diffusion,
                              "gamma" => γ,
                              "state_dim" => state_dim,
                              "param_infl" => param_infl
                             )
    
    # define the observation operator, observation error covariance and observations with
    # error observation covariance operator currently taken as a uniform scaling by default,
    # can be changed in the definition below
    obs = alternating_obs_operator(obs, obs_dim, kwargs)
    obs += obs_un * rand(Normal(), size(obs))
    obs_cov = obs_un^2.0 * I
    
    # we define the parameter sample as the key name and index
    # of the extended state vector pair, to be loaded in the
    # ensemble integration step
    if model == "L96"
        param_sample = Dict("F" => [41:41])
    elseif model == "IEEE39bus"
        param_sample = Dict("H" => [21:30], "D" => [31:40])
    end
    kwargs["param_sample"] = param_sample

    # create storage for the forecast and analysis statistics
    fore_rmse = Vector{Float64}(undef, nanl)
    filt_rmse = Vector{Float64}(undef, nanl)
    para_rmse = Vector{Float64}(undef, nanl)
    
    fore_spread = Vector{Float64}(undef, nanl)
    filt_spread = Vector{Float64}(undef, nanl)
    para_spread = Vector{Float64}(undef, nanl)

    # loop over the number of observation-forecast-analysis cycles
    for i in 1:nanl
        # for each ensemble member
        for j in 1:N_ens
            if  model == "IEEE39bus"
                # we define the diffusion structure matrix with respect to the sample value
                # of the inertia, as per each ensemble member
                diff_mat = zeros(20,20)
                diff_mat[LinearAlgebra.diagind(diff_mat)[11:end]] = 
                dx_params["ω"][1] ./ (2.0 * ens[21:30, j])
                
                kwargs["diff_mat"] = diff_mat
            end
            @views for k in 1:f_steps
                # loop over the integration steps between observations
                step_model!(ens[:, j], 0.0, kwargs)
                if model == "IEEE39bus"
                    # set phase angles mod 2pi
                    ens[1:10, j] .= rem2pi.(ens[1:10, j], RoundNearest)
                end
            end
        end
    
        # compute the forecast statistics
        fore_rmse[i], fore_spread[i] = analyze_ens(ens[1:state_dim, :], truth[:, i])

        # after the forecast step, perform assimilation of the observation
        analysis = ensemble_filter(method, ens, obs[:, i], obs_cov, state_infl, kwargs)
        ens = analysis["ens"]::Array{Float64,2}

        # extract the parameter ensemble for later usage
        param_ens = @view ens[state_dim+1:end, :]

        # compute the analysis statistics
        filt_rmse[i], filt_spread[i] = analyze_ens(ens[1:state_dim, :], truth[:, i])
        para_rmse[i], para_spread[i] = analyze_ens_para(param_ens, param_truth)

        # include random walk for the ensemble of parameters
        # with standard deviation given by the param_wlk scaling
        # of the mean vector
        param_mean = mean(param_ens, dims=2)
        param_ens .= param_ens + param_wlk * param_mean .* rand(Normal(),
                                                                length(param_truth), N_ens)
    end

    data = Dict{String,Any}(
                            "fore_rmse" => fore_rmse,
                            "filt_rmse" => filt_rmse,
                            "param_rmse" => para_rmse,
                            "fore_spread" => fore_spread,
                            "filt_spread" => filt_spread,
                            "param_spread" => para_spread,
                            "method" => method,
                            "seed" => seed, 
                            "diffusion" => diffusion,
                            "dx_params" => dx_params,
                            "param_truth" => param_truth,
                            "sys_dim" => sys_dim,
                            "state_dim" => state_dim,
                            "obs_dim" => obs_dim, 
                            "obs_un" => obs_un,
                            "gamma" => γ,
                            "param_err" => param_err,
                            "param_wlk" => param_wlk,
                            "nanl" => nanl,
                            "tanl" => tanl,
                            "h" => h,
                            "N_ens" => N_ens, 
                            "state_infl" => round(state_infl, digits=2),
                            "param_infl" => round(param_infl, digits=2)
                           )
    
    # check if there is a diffusion structure matrix
    if haskey(ts, "diff_mat")
        data["diff_mat"] = ts["diff_mat"]
    end

    path = joinpath(@__DIR__, "../data/", method * "/") 
    name =  method * 
            "_" * model *
            "_param_seed_" * lpad(seed, 4, "0") * 
            "_diff_" * rpad(diffusion, 5, "0") * 
            "_sysD_" * lpad(sys_dim, 2, "0") * 
            "_stateD_" * lpad(state_dim, 2, "0") * 
            "_obsD_" * lpad(obs_dim, 2, "0") * 
            "_obsU_" * rpad(obs_un, 4, "0") * 
            "_gamma_" * lpad(γ, 5, "0") * 
            "_paramE_" * rpad(param_err, 4, "0") * 
            "_paramW_" * rpad(param_wlk, 6, "0") * 
            "_nanl_" * lpad(nanl, 5, "0") * 
            "_tanl_" * rpad(tanl, 4, "0") * 
            "_h_" * rpad(h, 4, "0") * 
            "_nens_" * lpad(N_ens, 3, "0") * 
            "_stateInfl_" * rpad(round(state_infl, digits=2), 4, "0") *
            "_paramInfl_" * rpad(round(param_infl, digits=2), 4, "0") * 
            ".jld2"

    save(path * name, data)
    print("Runtime " * string(round((time() - t1)  / 60.0, digits=4))  * " minutes\n")
end


##############################################################################################
# end module

end

