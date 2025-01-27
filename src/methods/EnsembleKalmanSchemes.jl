##############################################################################################
module EnsembleKalmanSchemes
##############################################################################################
##############################################################################################
# imports and exports
using Random, Distributions, Statistics
using LinearAlgebra, SparseArrays
using Optim, LineSearches
export alternating_obs_operator, analyze_ens, analyze_ens_para, rand_orth, 
       inflate_state!, inflate_param!, transform, square_root, square_root_inv, 
       ensemble_filter, ls_smoother_classic,
       ls_smoother_single_iteration, ls_smoother_gauss_newton

##############################################################################################
##############################################################################################
# Type union declarations for multiple dispatch and type aliases

# covariance matrix types
CovM = Union{UniformScaling{Float64}, Diagonal{Float64}, Symmetric{Float64}}

# conditioning matrix types
ConM = Union{UniformScaling{Float64}, Symmetric{Float64}}

# right transform types, including soley a transform, or transform, weights rotation package
TransM = Union{Tuple{Symmetric{Float64,Array{Float64,2}},Array{Float64,2},Array{Float64,2}},
               Tuple{Symmetric{Float64,Array{Float64,2}},Array{Float64,1},Array{Float64,2}},
               Array{Float64,2}}

# vectors and ensemble members of sample
VecA = Union{Vector{Float64}, SubArray{Float64, 1}}

# arrays and views of arrays
ArView = Union{Array{Float64, 2}, SubArray{Float64, 2}}

##############################################################################################
##############################################################################################
# Main methods, debugged and validated
##############################################################################################
# alternating id obs

function alternating_obs_operator(ens::Array{Float64,2}, obs_dim::Int64,
                                  kwargs::Dict{String,Any})
    """Observation of alternating state vector components, possibly nonlinear transformation.

    This selects components to observe based on the observation dimension and if
    parameter estimation is being performed.  Parameters are always unobservable,
    and even states will be removed from the state vector until the observation dimension
    is appropriate.  Nonlinear observations are optional, as described for the
    Lorenz-96 model by Asch, Bocquet, Nodet pg. 181 """

    sys_dim, N_ens = size(ens)

    if haskey(kwargs, "state_dim")
        # performing parameter estimation, load the dynamic state dimension
        state_dim = kwargs["state_dim"]::Int64
        
        # observation operator for extended state, without observing extended state components
        obs = copy(ens[1:state_dim, :])
        
        # proceed with alternating observations of the regular state vector
        sys_dim = state_dim
    else
        obs = copy(ens)
    end

    if obs_dim == sys_dim

    elseif (obs_dim / sys_dim) > 0.5
        # the observation dimension is greater than half the state dimension, so we
        # remove only the trailing odd-index rows equal to the difference
        # of the state and observation dimension
        R = sys_dim - obs_dim
        indx = 1:(sys_dim - 2 * R)
        indx = [indx; sys_dim - 2 * R + 2: 2: sys_dim]
        obs = obs[indx, :]

    elseif (obs_dim / sys_dim) == 0.5
        # the observation dimension is equal to half the state dimension so we remove exactly
        # half the rows, corresponding to those with even-index
        obs = obs[1:2:sys_dim, :]

    else
        # the observation dimension is less than half of the state dimension so that we
        # remove all even rows and then all but the remaining, leading obs_dim rows
        obs = obs[1:2:sys_dim, :]
        obs = obs[1:obs_dim, :]
    end
        
    γ = kwargs["gamma"]::Float64
    if γ > 1.0
        # sets nonlinear observation as given on page 181, Asch, Bocquet, Nodet
        for i in 1:N_ens
            x = obs[:, i]
            obs[:, i]  = (x / 2.0) .* ( 1.0 .+ ( abs.(x) / 10.0 ).^(γ - 1.0) )
        end
    elseif γ == 0.0
        # sets quadratic observation operator as given by Hoteit, Luo, Pham
        obs .= 0.05*obs.^2.0
    elseif γ < 0.0
        # sets exponential mapping observation operator as given by 
        # Wu et al. Nonlin. Processes Geophys., 21, 955–970, 2014
        for i in 1:N_ens
            x = obs[:, i]
            obs[:, i] = x .* exp.(-γ * x)
        end
    end
    return obs
end


##############################################################################################
# ensemble state statistics

function analyze_ens(ens::ArView, truth::Vector{Float64})
    """Computes the ensemble RMSE as compared with truth twin, and the ensemble spread."""

    # infer the shapes
    sys_dim, N_ens = size(ens)

    # compute the ensemble mean
    x_bar = mean(ens, dims=2)

    # compute the RMSE of the ensemble mean
    rmse = sqrt(mean( (truth - x_bar).^2.0))

    # compute the spread as in whitaker & louge 98 by the standard deviation 
    # of the mean square deviation of the ensemble from its mean
    spread = sqrt( ( 1.0 / (N_ens - 1.0) ) * sum(mean((ens .- x_bar).^2.0, dims=1)))

    # return the tuple pair
    rmse, spread
end


##############################################################################################
# ensemble parameter statistics

function analyze_ens_para(ens::ArView, truth::Vector{Float64})
    """Computes the ensemble RMSE as compared with truth twin, and the ensemble spread."""

    # infer the shapes
    param_dim, N_ens = size(ens)

    # compute the ensemble mean
    x_bar = mean(ens, dims=2)

    # compute the RMSE of relative to the magnitude of the parameter
    rmse = sqrt( mean( (truth - x_bar).^2.0 ./ truth.^2.0 ) )

    # compute the spread as in whitaker & louge 98 by the standard deviation
    # of the mean square deviation of the ensemble from its mean,
    # with the weight by the size of the parameter square
    spread = sqrt( ( 1.0 / (N_ens - 1.0) ) * 
                   sum(mean( (ens .- x_bar).^2.0 ./ 
                             (ones(param_dim, N_ens) .* truth.^2.0), dims=1)))
    
    # return the tuple pair
    rmse, spread
end


##############################################################################################
# random mean preserving orthogonal matrix, auxilliary function for determinstic EnKF schemes

function rand_orth(N_ens::Int64)
    """This generates a mean preserving random orthogonal matrix as in sakov oke 08"""
    
    # generate the random, mean preserving orthogonal transformation within the 
    # basis given by the B matrix
    Q = rand(Normal(), N_ens - 1, N_ens - 1)
    Q, R = qr!(Q)
    U_p =  zeros(N_ens, N_ens)
    U_p[1, 1] = 1.0
    U_p[2:end, 2:end] = Q

    # generate the B basis for which the first basis vector is the vector of 1/sqrt(N)
    b_1 = ones(N_ens) / sqrt(N_ens)
    B = zeros(N_ens, N_ens)
    B[:, 1] = b_1

    # note, this uses the "full" QR decomposition so that the singularity is encoded in R
    # and B is a full-size orthogonal matrix
    B, R = qr!(B)
    B * U_p * transpose(B)
end


##############################################################################################
# dynamic state variable inflation

function inflate_state!(ens::Array{Float64,2}, inflation::Float64, sys_dim::Int64,
                        state_dim::Int64)
    """State variables are assumed to be in the leading rows, while extended
    state variables, parameter variables are after.
    
    Multiplicative inflation is performed only in the leading components."""

    if inflation != 1.0
        x_mean = mean(ens, dims=2)
        X = ens .- x_mean
        infl =  Matrix(1.0I, sys_dim, sys_dim) 
        infl[1:state_dim, 1:state_dim] .*= inflation 
        ens .= x_mean .+ infl * X
    end
end


##############################################################################################
# parameter multiplicative inflation

function inflate_param!(ens::Array{Float64,2}, inflation::Float64, sys_dim::Int64,
                        state_dim::Int64)
    """State variables are assumed to be in the leading rows, while extended
    state, parameter variables are after.
    
    Multiplicative inflation is performed only in the trailing components."""

    if inflation == 1.0
        return ens
    else
        x_mean = mean(ens, dims=2)
        X = ens .- x_mean
        infl =  Matrix(1.0I, sys_dim, sys_dim) 
        infl[state_dim+1: end, state_dim+1: end] .*= inflation
        ens .= x_mean .+ infl * X
    end
end


##############################################################################################
# auxiliary function for square roots of multiple types of covariance matrices wrapped 

function square_root(M::T) where {T <: CovM}
    
    if T <: UniformScaling
        M^0.5
    elseif T <: Diagonal
        sqrt(M)
    else
        # stable square root for close-to-singular inverse calculations
        F = svd(M)
        Symmetric(F.U * Diagonal(sqrt.(F.S)) * F.Vt)
    end
end


##############################################################################################
# auxiliary function for square root inverses of multiple types of covariance matrices wrapped

function square_root_inv(M::T; sq_rt::Bool=false, inverse::Bool=false,
                         full::Bool=false) where {T <: CovM}
    # if sq_rt=true will return the square root additionally for later use
    # as part of the calculation, if full, will make a computation of the inverse
    # simultaneously and return the square root inverse, square root, and inverse all
    # togeter
    if T <: UniformScaling
        if sq_rt
            S = M^0.5
            S^(-1.0), S
        elseif inverse
            S^(-1.0), M^(-1.0)
        elseif full
            S = M^0.5
            S^(-1.0), S, M^(-1.0)
        else
            M^(-0.5)
        end
    elseif T <: Diagonal
        if sq_rt 
            S = sqrt(M)
            inv(S), S
        elseif inverse
            S = sqrt(M)
            inv(S), inv(M)
        elseif full
            S = sqrt(M)
            inv(S), S, M^(-1.0)
        else
            inv(sqrt(M))
        end
    else
        # stable square root inverse for close-to-singular inverse calculations
        F = svd(M)
        if sq_rt 
            # take advantage of the SVD calculation to produce both the square root inverse
            # and square root simultaneously
            Symmetric(F.U * Diagonal(1.0 ./ sqrt.(F.S)) * F.Vt), 
            Symmetric(F.U * Diagonal(sqrt.(F.S)) * F.Vt) 
        elseif inverse
            # take advantage of the SVD calculation to produce the square root inverse
            # and inverse calculations all at once
            Symmetric(F.U * Diagonal(1.0 ./ sqrt.(F.S)) * F.Vt), 
            Symmetric(F.U * Diagonal(1.0 ./ F.S) * F.Vt)
        elseif full
            # take advantage of the SVD calculation to produce the square root inverse,
            # square root and inverse calculations all at once
            Symmetric(F.U * Diagonal(1.0 ./ sqrt.(F.S)) * F.Vt), 
            Symmetric(F.U * Diagonal(sqrt.(F.S)) * F.Vt),
            Symmetric(F.U * Diagonal(1.0 ./ F.S) * F.Vt)
        else
            # only return the square root inverse, if other calculations are not necessary
            Symmetric(F.U * Diagonal(1.0 ./ sqrt.(F.S)) * F.Vt)
        end
    end
end


##############################################################################################
# transform auxilliary function for EnKF, ETKF(-N), EnKS, ETKS(-N), IEnKS(-N)

function transform(analysis::String, ens::Array{Float64,2}, obs::Vector{Float64}, 
                   obs_cov::CovM, kwargs::Dict{String,Any}; conditioning::ConM=1000.0I, 
                   m_err::Array{Float64,2}=(1.0 ./ zeros(1,1)),
                   tol::Float64 = 0.0001,
                   j_max::Int64=40,
                   Q::CovM=1.0I)
    """Computes transform and related values for various flavors of ensemble Kalman schemes.

    "analysis" is a string which determines the type of transform update.  The observation
    error covariance should be of UniformScaling, Diagonal or Symmetric type."""

    if analysis=="enkf" || analysis=="enks"
        ## This computes the stochastic transform for the EnKF/S as in Carrassi, et al. 2018
        # step 0: infer the ensemble, obs, and state dimensions
        sys_dim, N_ens = size(ens)
        obs_dim = length(obs)

        # step 1: generate the unbiased perturbed observations, note,
        # we use the actual observation error covariance instead of the ensemble-based
        # covariance to handle rank degeneracy
        obs_perts = rand(MvNormal(zeros(obs_dim), obs_cov), N_ens)
        obs_perts = obs_perts .- mean(obs_perts, dims=2)

        # step 2: compute the observation ensemble
        obs_ens = obs .+ obs_perts

        # step 3: generate the ensemble transform matrix
        Y = alternating_obs_operator(ens, obs_dim, kwargs)
        S = (Y .- mean(Y, dims=2)) / sqrt(N_ens - 1.0)
        C = Symmetric(S * transpose(S) + obs_cov)
        transform = 1.0I + transpose(S) * inv(C) * (obs_ens - Y) / sqrt(N_ens - 1.0)
        
    elseif analysis=="etkf" || analysis=="etks"
        ## This is the default method for the ensemble square root transform
        # step 0: infer the system, observation and ensemble dimensions 
        sys_dim, N_ens = size(ens)
        obs_dim = length(obs)

        # step 1: compute the ensemble in observation space
        Y = alternating_obs_operator(ens, obs_dim, kwargs)

        # step 2: compute the ensemble mean in observation space
        y_mean = mean(Y, dims=2)
        
        # step 3: compute the sensitivity matrix in observation space
        obs_sqrt_inv = square_root_inv(obs_cov)
        S = obs_sqrt_inv * (Y .- y_mean )

        # step 4: compute the weighted innovation
        δ = obs_sqrt_inv * ( obs - y_mean )
       
        # step 5: compute the approximate hessian
        hessian = Symmetric((N_ens - 1.0)*I + transpose(S) * S)
        
        # step 6: compute the transform matrix, transform matrix inverse and
        # hessian inverse simultaneously via the SVD for stability
        T, hessian_inv = square_root_inv(hessian, inverse=true)
        
        # step 7: compute the analysis weights
        w = hessian_inv * transpose(S) * δ

        # step 8: generate mean preserving random orthogonal matrix as in sakov oke 08
        U = rand_orth(N_ens)

        # step 9: package the transform output tuple
        T, w, U
    
    elseif analysis[1:7]=="mlef-ls" || analysis[1:7]=="mles-ls"
        # Computes the tuned inflation, iterative ETKF cost function in the MLEF
        # formalism, pg. 180 Asch, Bocquet, Nodet
        # uses Newton-based minimiztion with linesearch
        
        # step 0: infer the system, observation and ensemble dimensions 
        sys_dim, N_ens = size(ens)
        obs_dim = length(obs)
        
        # step 1: set up inputs for the optimization 
        
        # step 1a: inial choice is no change to the mean state
        ens_mean_0 = mean(ens, dims=2)
        anom_0 = ens .- ens_mean_0
        w = zeros(N_ens)

        # step 1b: pre-compute the observation error covariance square root
        obs_sqrt_inv = square_root_inv(obs_cov)

        # step 1c: define the conditioning and parameters for finite size formalism if needed
        if analysis[end-5:end] == "bundle"
            T = inv(conditioning) 
            T_inv = conditioning
        elseif analysis[end-8:end] == "transform"
            T = Symmetric(Matrix(1.0*I, N_ens, N_ens))
            T_inv = Symmetric(Matrix(1.0*I, N_ens, N_ens))
        end

        if analysis[8:9] == "-n"
            # define the epsilon scaling and the effective ensemble size if finite size form
            ϵ_N = 1.0 + (1.0 / N_ens)
            N_effective = N_ens + 1.0
        end

        # step 1d: define the storage of the gradient and Hessian as global to the functions
        grad_w = Vector{Float64}(undef, N_ens)
        hess_w = Array{Float64}(undef, N_ens, N_ens)
        cost_w = 0.0

        # step 2: define the cost / gradient / hessian function to avoid repeated computations
        function fgh!(G, H, C, T::ConM, T_inv::ConM, w::Vector{Float64})
            # step 2a: define the linearization of the observation operator 
            ens_mean_iter = ens_mean_0 + anom_0 * w
            ens = ens_mean_iter .+ anom_0 * T 
            Y = alternating_obs_operator(ens, obs_dim, kwargs)
            y_mean = mean(Y, dims=2)

            # step 2b: compute the weighted anomalies in observation space, conditioned
            # with T inverse
            S = obs_sqrt_inv * (Y .- y_mean) * T_inv 

            # step 2c: compute the weighted innovation
            δ = obs_sqrt_inv * (obs - y_mean)
        
            # step 2d: gradient, hessian and cost function definitions
            if G != nothing
                if analysis[8:9] == "-n"
                    ζ = 1.0 / (ϵ_N + sum(w.^2.0))
                    G[:] = N_effective * ζ * w - transpose(S) * δ
                else
                    G[:] = (N_ens - 1.0)  * w - transpose(S) * δ
                end
            end
            if H != nothing
                if analysis[8:9] == "-n"
                    H .= Symmetric((N_effective - 1.0)*I + transpose(S) * S)
                else
                    H .= Symmetric((N_ens - 1.0)*I + transpose(S) * S)
                end
            end
            if C != nothing
                if analysis[8:9] == "-n"
                    y_mean_iter = alternating_obs_operator(ens_mean_iter, obs_dim, kwargs)
                    δ = obs_sqrt_inv * (obs - y_mean_iter)
                    return N_effective * log(ϵ_N + sum(w.^2.0)) + sum(δ.^2.0)
                else
                    y_mean_iter = alternating_obs_operator(ens_mean_iter, obs_dim, kwargs)
                    δ = obs_sqrt_inv * (obs - y_mean_iter)
                    return (N_ens - 1.0) * sum(w.^2.0) + sum(δ.^2.0)
                end
            end
            nothing
        end
        function newton_ls!(grad_w, hess_w, T::ConM, T_inv::ConM, w::Vector{Float64}, 
                          linesearch)
            # step 2e: find the Newton direction and the transform update if needed
            fx = fgh!(grad_w, hess_w, cost_w, T, T_inv, w)
            p = -hess_w \ grad_w
            if analysis[end-8:end] == "transform"
                T_tmp, T_inv_tmp = square_root_inv(Symmetric(hess_w), sq_rt=true)
                T .= T_tmp
                T_inv .= T_inv_tmp
            end
            
            # step 2f: univariate line search functions
            ϕ(α) = fgh!(nothing, nothing, cost_w, T, T_inv, w .+ α.*p)
            function dϕ(α)
                fgh!(grad_w, nothing, nothing, T, T_inv, w .+ α.*p)
                return dot(grad_w, p)
            end
            function ϕdϕ(α)
                phi = fgh!(grad_w, nothing, cost_w, T, T_inv, w .+ α.*p)
                dphi = dot(grad_w, p)
                return (phi, dphi)
            end

            # step 2g: define the linesearch
            dϕ_0 = dot(p, grad_w)
            α, fx = linesearch(ϕ, dϕ, ϕdϕ,  1.0, fx, dϕ_0)
            Δw = α * p
            w .= w + Δw
            
            return Δw
        end
        
        # step 3: optimize
        # step 3a: perform the optimization by Newton with linesearch
        # we use StrongWolfe for RMSE performance as the default linesearch
        #ln_search = HagerZhang()
        ln_search = StrongWolfe()
        j = 0
        Δw = ones(N_ens)

        while j < j_max && norm(Δw) > tol
            Δw = newton_ls!(grad_w, hess_w, T, T_inv, w, ln_search)
        end
        
        if analysis[8:9] == "-n"
            # peform a final inflation with the finite size cost function
            ζ = 1.0 / (ϵ_N + sum(w.^2.0))
            hess_w = ζ * I - 2.0 * ζ^2.0 * w * transpose(w) 
            hess_w = Symmetric(transpose(S) * S + (N_ens + 1.0) * hess_w)
            T = square_root_inv(hess_w)
        
        elseif analysis[end-5:end] == "bundle"
            T = square_root_inv(hess_w)
        end

        # step 3b:  generate mean preserving random orthogonal matrix as in sakov oke 08
        U = rand_orth(N_ens)

        # step 4: package the transform output tuple
        T, w, U
    
    elseif analysis[1:4]=="mlef" || analysis[1:4]=="mles"
        # step 0: infer the system, observation and ensemble dimensions 
        sys_dim, N_ens = size(ens)
        obs_dim = length(obs)
        
        # step 1: set up the optimization, inial choice is no change to the mean state
        ens_mean_0 = mean(ens, dims=2)
        anom_0 = ens .- ens_mean_0
        w = zeros(N_ens)

        # pre-compute the observation error covariance square root
        obs_sqrt_inv = square_root_inv(obs_cov)

        # define these variables as global compared to the while loop
        grad_w = Vector{Float64}(undef, N_ens)
        hess_w = Array{Float64}(undef, N_ens, N_ens)
        S = Array{Float64}(undef, obs_dim, N_ens)
        ens_mean_iter = copy(ens_mean_0)

        # define the conditioning 
        if analysis[end-5:end] == "bundle"
            T = inv(conditioning) 
            T_inv = conditioning
        elseif analysis[end-8:end] == "transform"
            T = 1.0*I
            T_inv = 1.0*I
        end
        
        # step 2: perform the optimization by simple Newton
        j = 0
        if analysis[5:6] == "-n"
            # define the epsilon scaling and the effective ensemble size if finite size form
            ϵ_N = 1.0 + (1.0 / N_ens)
            N_effective = N_ens + 1.0
        end
        
        while j < j_max
            # step 2a: compute the observed ensemble and ensemble mean 
            ens_mean_iter = ens_mean_0 + anom_0 * w
            ens = ens_mean_iter .+ anom_0 * T
            Y = alternating_obs_operator(ens, obs_dim, kwargs)
            y_mean = mean(Y, dims=2)

            # step 2b: compute the weighted anomalies in observation space, conditioned
            # with T inverse
            S = obs_sqrt_inv * (Y .- y_mean) * T_inv 

            # step 2c: compute the weighted innovation
            δ = obs_sqrt_inv * (obs - y_mean)
        
            # step 2d: compute the gradient and hessian
            if analysis[5:6] == "-n" 
                # for finite formalism, we follow the IEnKS-N convention where
                # the gradient is computed with the finite-size cost function but we use the
                # usual hessian, with the effective ensemble size
                ζ = 1.0 / (ϵ_N + sum(w.^2.0))
                grad_w = N_effective * ζ * w - transpose(S) * δ
                hess_w = Symmetric((N_effective - 1.0)*I + transpose(S) * S)
            else
                grad_w = (N_ens - 1.0)  * w - transpose(S) * δ
                hess_w = Symmetric((N_ens - 1.0)*I + transpose(S) * S)
            end
            
            # step 2e: perform Newton approximation, simultaneously computing
            # the update transform T with the SVD based inverse at once
            if analysis[end-8:end] == "transform"
                T, T_inv, hessian_inv = square_root_inv(hess_w, full=true)
                Δw = hessian_inv * grad_w 
            else
                Δw = hess_w \ grad_w
            end

            # 2f: update the weights
            w -= Δw 
            
            if norm(Δw) < tol
                break
            else
                # step 2g: update the iterative mean state
                j+=1
            end
        end

        if analysis[5:6] == "-n"
            # peform a final inflation with the finite size cost function
            ζ = 1.0 / (ϵ_N + sum(w.^2.0))
            hess_w = ζ * I - 2.0 * ζ^2.0 * w * transpose(w) 
            hess_w = Symmetric(transpose(S) * S + (N_ens + 1.0) * hess_w)
            T = square_root_inv(hess_w)
        
        elseif analysis[end-5:end] == "bundle"
            T = square_root_inv(hess_w)
        end

        # step 7:  generate mean preserving random orthogonal matrix as in sakov oke 08
        U = rand_orth(N_ens)

        # step 8: package the transform output tuple
        T, w, U
    
    elseif analysis=="etkf-sqrt-core" || analysis=="etks-sqrt-core"
        ### NOTE: STILL DEVELOPMENT CODE, NOT DEBUGGED 
        # needs to be revised for the calculation with unweighted anomalies
        # Uses the contribution of the model error covariance matrix Q
        # in the square root as in Raanes et al. 2015
        # step 0: infer the system, observation and ensemble dimensions 
        sys_dim, N_ens = size(ens)
        obs_dim = length(obs)

        # step 1: compute the ensemble mean
        x_mean = mean(ens, dims=2)

        # step 2a: compute the normalized anomalies
        A = (ens .- x_mean) / sqrt(N_ens - 1.0)

        # step 2b: compute the SVD for the two-sided projected model error covariance
        F = svd(A)
        Σ_inv = Diagonal([1.0 ./ F.S[1:N_ens-1]; 0.0]) 
        p_inv = F.V * Σ_inv * transpose(F.U)
        ## NOTE: want to
        G = Symmetric(1.0I + (N_ens - 1.0) * p_inv * Q * transpose(p_inv))
        
        # step 2c: compute the model error adjusted anomalies
        A = A * square_root(G)

        # step 3: compute the ensemble in observation space
        Y = alternating_obs_operator(ens, obs_dim, kwargs)

        # step 4: compute the ensemble mean in observation space
        y_mean = mean(Y, dims=2)
        
        # step 5: compute the weighted anomalies in observation space
        
        # first we find the observation error covariance inverse
        obs_sqrt_inv = square_root_inv(obs_cov)
        
        # then compute the weighted anomalies
        S = (Y .- y_mean) / sqrt(N_ens - 1.0)
        S = obs_sqrt_inv * S

        # step 6: compute the weighted innovation
        δ = obs_sqrt_inv * ( obs - y_mean )
       
        # step 7: compute the transform matrix
        T = inv(Symmetric(1.0I + transpose(S) * S))
        
        # step 8: compute the analysis weights
        w = T * transpose(S) * δ

        # step 9: compute the square root of the transform
        T = sqrt(T)
        
        # step 10:  generate mean preserving random orthogonal matrix as in sakov oke 08
        U = rand_orth(N_ens)

        # step 11: package the transform output tuple
        T, w, U

    elseif analysis=="enkf-n-dual" || analysis=="enks-n-dual"
        # Computes the dual form of the EnKF-N transform as in bocquet, raanes, hannart 2015
        # NOTE: This cannot be used with the nonlinear observation operator.
        # This uses the Brent method for the argmin problem as this
        # has been more reliable at finding a global minimum than Newton optimization.
        # step 0: infer the system, observation and ensemble dimensions 
        sys_dim, N_ens = size(ens)
        obs_dim = length(obs)

        # step 1: compute the observed ensemble and ensemble mean
        Y = alternating_obs_operator(ens, obs_dim, kwargs)
        y_mean = mean(Y, dims=2)

        # step 2: compute the weighted anomalies in observation space
        
        # first we find the observation error covariance inverse
        obs_sqrt_inv = square_root_inv(obs_cov)
        
        # then compute the sensitivity matrix in observation space 
        S = obs_sqrt_inv * (Y .- y_mean)
 
        # step 5: compute the weighted innovation
        δ = obs_sqrt_inv * (obs - y_mean)
        
        # step 6: compute the SVD for the simplified cost function, gauge weights and range
        F = svd(S)
        ϵ_N = 1.0 + (1.0 / N_ens)
        ζ_l = 0.000001
        ζ_u = (N_ens + 1.0) / ϵ_N
        
        # step 7: define the dual cost function derived in singular value form
        function D(ζ::Float64)
            cost = I - (F.U * Diagonal( F.S.^2.0 ./ (ζ .+ F.S.^2.0) ) * transpose(F.U) )
            cost = transpose(δ) * cost * δ .+ ϵ_N * ζ .+
                   (N_ens + 1.0) * log((N_ens + 1.0) / ζ) .- (N_ens + 1.0)
            cost[1]
        end
        
        # The below is defined for possible Hessian-based minimization 
        # NOTE: standard Brent's method appears to be more reliable at finding a
        # global minimizer with some basic tests, may be tested further
        #
        #function D_v(ζ::Vector{Float64})
        #    ζ = ζ[1]
        #    cost = I - (F.U * Diagonal( F.S.^2.0 ./ (ζ .+ F.S.^2.0) ) * transpose(F.U) )
        #    cost = transpose(δ) * cost * δ .+ ϵ_N * ζ .+
        #    (N_ens + 1.0) * log((N_ens + 1.0) / ζ) .- (N_ens + 1.0)
        #    cost[1]
        #end

        #function D_prime!(storage::Vector{Float64}, ζ::Vector{Float64})
        #    ζ = ζ[1]
        #    grad = transpose(δ) * F.U * Diagonal( - F.S.^2.0 .* (ζ .+ F.S.^2.0).^(-2.0) ) *
        #           transpose(F.U) * δ
        #    storage[:, :] = grad .+ ϵ_N  .- (N_ens + 1.0) / ζ
        #end

        #function D_hess!(storage::Array{Float64}, ζ::Vector{Float64})
        #    ζ = ζ[1]
        #    hess = transpose(δ) * F.U *
        #           Diagonal( 2.0 * F.S.^2.0 .* (ζ .+ F.S.^2.0).^(-3.0) ) * transpose(F.U) * δ
        #    storage[:, :] = hess .+ (N_ens + 1.0) * ζ^(-2.0)
        #end

        #lx = [ζ_l]
        #ux = [ζ_u]
        #ζ_0 = [(ζ_u + ζ_l)/2.0]
        #df = TwiceDifferentiable(D_v, D_prime!, D_hess!, ζ_0)
        #dfc = TwiceDifferentiableConstraints(lx, ux)
        #ζ_b = optimize(D_v, D_prime!, D_hess!, ζ_0)


        # step 8: find the argmin
        ζ_a = optimize(D, ζ_l, ζ_u)
        diag_vals = ζ_a.minimizer .+ F.S.^2.0

        # step 9: compute the update weights
        w = F.V * Diagonal( F.S ./ diag_vals ) * transpose(F.U) * δ 

        # step 10: compute the update transform
        T = Symmetric(Diagonal( F.S ./ diag_vals) * transpose(F.U) * δ * 
                               transpose(δ) * F.U * Diagonal( F.S ./ diag_vals))
        T = Symmetric(Diagonal(diag_vals) - 
                               ( (2.0 * ζ_a.minimizer^2.0) / (N_ens + 1.0) ) * T)
        T = Symmetric(F.V * square_root_inv(T) * F.Vt)
        
        # step 11:  generate mean preserving random orthogonal matrix as in sakov oke 08
        U = rand_orth(N_ens)

        # step 12: package the transform output tuple
        T, w, U
    
    elseif analysis=="enkf-n-primal" || analysis=="enks-n-primal"
        # Computes the primal form of the EnKF-N transform as in bocquet, raanes, hannart 2015
        # This differs from the MLEF/S-N in that there is no linearization of the observation
        # operator, this only handles this with respect to the adaptive inflation.
        # This uses the standard Gauss-Newton-based minimization of the cost function
        # for the adaptive inflation, whereas enkf-n-ls / enks-n-ls uses the
        # optimized linesearch
        # step 0: infer the system, observation and ensemble dimensions 
        sys_dim, N_ens = size(ens)
        obs_dim = length(obs)

        # step 1: compute the observed ensemble and ensemble mean 
        Y = alternating_obs_operator(ens, obs_dim, kwargs)
        y_mean = mean(Y, dims=2)

        # step 2: compute the weighted anomalies in observation space
        
        # first we find the observation error covariance inverse
        obs_sqrt_inv = square_root_inv(obs_cov)
        
        # then compute the sensitivity matrix in observation space 
        S = obs_sqrt_inv * (Y .- y_mean)

        # step 3: compute the weighted innovation
        δ = obs_sqrt_inv * (obs - y_mean)
        
        # step 4: define the epsilon scaling and the effective ensemble size
        ϵ_N = 1.0 + (1.0 / N_ens)
        N_effective = N_ens + 1.0
        
        # step 5: set up the optimization
        # step 5:a the inial choice is no change to the mean state
        w = zeros(N_ens)
        
        # step 5b: define the primal cost function
        function P(w::Vector{Float64})
            cost = (δ - S * w)
            cost = sum(cost.^2.0) + N_effective * log(ϵ_N + sum(w.^2.0))
            0.5 * cost
        end

        # step 5c: define the primal gradient
        function ∇P!(grad::Vector{Float64}, w::Vector{Float64})
            ζ = 1.0 / (ϵ_N + sum(w.^2.0))
            grad[:] = N_effective * ζ * w - transpose(S) * (δ - S * w) 
        end

        # step 5d: define the primal hessian
        function H_P!(hess::Array{Float64,2}, w::Vector{Float64})
            ζ = 1.0 / (ϵ_N + sum(w.^2.0))
            hess .= ζ * I - 2.0 * ζ^2.0 * w * transpose(w) 
            hess .= transpose(S) * S + N_effective * hess
        end
        
        # step 6: perform the optimization by simple Newton
        j = 0
        T = Array{Float64}(undef, N_ens, N_ens)
        grad_w = Array{Float64}(undef, N_ens)
        hess_w = Array{Float64}(undef, N_ens, N_ens)

        while j < j_max
            # compute the gradient and hessian
            ∇P!(grad_w, w)
            H_P!(hess_w, w)
            
            # perform Newton approximation, simultaneously computing
            # the update transform T with the SVD based inverse at once
            T, hessian_inv = square_root_inv(Symmetric(hess_w), inverse=true)
            Δw = hessian_inv * grad_w 
            w -= Δw 
            
            if norm(Δw) < tol
                break
            else
                j+=1
            end
        end

        # step 7:  generate mean preserving random orthogonal matrix as in sakov oke 08
        U = rand_orth(N_ens)

        # step 8: package the transform output tuple
        T, w, U
    
    elseif analysis=="enkf-n-primal-ls" || analysis=="enks-n-primal-ls"
        # Computes the primal form of the EnKF-N transform as in bocquet, raanes, hannart 2015
        # Differs from the MLEF/S-N in that there is no linearization of the observation
        # operator, this only handles this with respect to the adaptive inflation.
        # This uses linesearch with the strong Wolfe condition as the basis for the
        # Newton-based minimization of the cost function for the adaptive inflation
        # by default. May also use other line-search methods, with HagerZhang the next
        # best option by initial tests
        # step 0: infer the system, observation and ensemble dimensions 
        sys_dim, N_ens = size(ens)
        obs_dim = length(obs)

        # step 1: compute the observed ensemble and ensemble mean 
        Y = alternating_obs_operator(ens, obs_dim, kwargs)
        y_mean = mean(Y, dims=2)

        # step 2: compute the weighted anomalies in observation space
        
        # first we find the observation error covariance inverse
        obs_sqrt_inv = square_root_inv(obs_cov)
        
        # then compute the sensitivity matrix in observation space 
        S = obs_sqrt_inv * (Y .- y_mean)

        # step 3: compute the weighted innovation
        δ = obs_sqrt_inv * (obs - y_mean)
        
        # step 4: define the epsilon scaling and the effective ensemble size
        ϵ_N = 1.0 + (1.0 / N_ens)
        N_effective = N_ens + 1.0
        
        # step 5: set up the optimization
        
        # step 5:a the inial choice is no change to the mean state
        w = zeros(N_ens)
        
        # step 5b: define the primal cost function
        function J(w::Vector{Float64})
            cost = (δ - S * w)
            cost = sum(cost.^2.0) + N_effective * log(ϵ_N + sum(w.^2.0))
            0.5 * cost
        end

        # step 5c: define the primal gradient
        function ∇J!(grad::Vector{Float64}, w::Vector{Float64})
            ζ = 1.0 / (ϵ_N + sum(w.^2.0))
            grad[:] = N_effective * ζ * w - transpose(S) * (δ - S * w) 
        end

        # step 5d: define the primal hessian
        function H_J!(hess::Array{Float64,2}, w::Vector{Float64})
            ζ = 1.0 / (ϵ_N + sum(w.^2.0))
            hess .= ζ * I - 2.0 * ζ^2.0 * w * transpose(w) 
            hess .= transpose(S) * S + N_effective * hess
        end
        
        # step 6: find the argmin for the update weights
        # step 6a: define the line search algorithm with Newton
        # we use StrongWolfe for RMSE performance as the default linesearch
        # method, see the LineSearches docs, alternative choice is commented below
        # ln_search = HagerZhang()
        ln_search = StrongWolfe()
        opt_alg = Newton(linesearch = ln_search)

        # step 6b: perform the optimization
        w = Optim.optimize(J, ∇J!, H_J!, w, method=opt_alg, x_tol=tol).minimizer

        # step 7: compute the update transform
        T = Symmetric(H_J!(Array{Float64}(undef, N_ens, N_ens), w))
        T = square_root_inv(T)
        
        # step 8:  generate mean preserving random orthogonal matrix as in sakov oke 08
        U = rand_orth(N_ens)

        # step 9: package the transform output tuple
        T, w, U
    
    elseif analysis[1:5]=="ienks" 
        # this computes the weighted observed anomalies as per the  
        # bundle or transform version of the IEnKS -- bundle uses a small uniform 
        # scalar epsilon, transform uses a matrix as the conditioning, 
        # with bundle used by default this returns a sequential-in-time value for 
        # the cost function gradient and hessian
        
        # step 0: infer observation dimension
        obs_dim = length(obs)
        
        # step 1: compute the observed ensemble and ensemble mean 
        Y = alternating_obs_operator(ens, obs_dim, kwargs)
        y_mean = mean(Y, dims=2)
        
        # step 2: compute the observed anomalies, proportional to the conditioning matrix
        # here conditioning should be supplied as T^(-1)
        S = (Y .- y_mean) * conditioning

        # step 3: compute the cost function gradient term
        inv_obs_cov = inv(obs_cov)
        ∇J = transpose(S) * inv_obs_cov * (obs - y_mean)

        # step 4: compute the cost function gradient term
        hess_J = transpose(S) * inv_obs_cov * S

        # return tuple of the gradient and hessian terms
        ∇J, hess_J
    end
end


##############################################################################################
# auxilliary function for updating ensembles 

function ens_update!(ens::ArView, transform::T1) where {T1 <: TransM}
    """ Updates ensemble by right-transform method

    In the case where this follows the stochastic EnKF as in Carrassi et al. 2018,
    this simply performs right mutliplication.  All other cases use the 3-tuple including
    the right transform for the anomalies, the weights for the mean and the random, mean-
    preserving orthogonal matrix."""

    if T1 <: Array{Float64,2}
        # step 1: update the ensemble with right transform
        ens .= ens * transform 
    
    else
        # step 0: infer dimensions and unpack the transform
        sys_dim, N_ens = size(ens)
        T, w, U = transform
        
        # step 1: compute the ensemble mean
        x_mean = mean(ens, dims=2)

        # step 2: compute the non-normalized anomalies
        X = ens .- x_mean

        # step 3: compute the update
        ens_transform = w .+ T * U * sqrt(N_ens - 1.0)
        ens .= x_mean .+ X * ens_transform
    end
end


##############################################################################################
# general filter code 

function ensemble_filter(analysis::String, ens::Array{Float64,2}, obs::Vector{Float64}, 
                         obs_cov::CovM, state_infl::Float64, kwargs::Dict{String,Any})

    """General filter analysis step

    Optional keyword argument includes state_dim for extended state including parameters.
    In this case, a value for the parameter covariance inflation should be included
    in addition to the state covariance inflation."""

    # step 0: infer the system, observation and ensemble dimensions 
    sys_dim, N_ens = size(ens)
    obs_dim = length(obs)

    if haskey(kwargs, "state_dim")
        state_dim = kwargs["state_dim"]
        param_infl = kwargs["param_infl"]

    else
        state_dim = sys_dim
    end

    # step 1: compute the tranform and update ensemble
    ens_update!(ens, transform(analysis, ens, obs, obs_cov, kwargs)) 

    # step 2a: compute multiplicative inflation of state variables
    inflate_state!(ens, state_infl, sys_dim, state_dim)

    # step 2b: if including an extended state of parameter values,
    # compute multiplicative inflation of parameter values
    if state_dim != sys_dim
        inflate_param!(ens, param_infl, sys_dim, state_dim)
    end

    Dict{String,Array{Float64,2}}("ens" => ens)
end


##############################################################################################
# classical version lag_shift_smoother

function ls_smoother_classic(analysis::String, ens::Array{Float64,2}, obs::Array{Float64,2}, 
                             obs_cov::CovM, state_infl::Float64, kwargs::Dict{String,Any})

    """Lag-shift ensemble kalman smoother analysis step, classical version

    Classic enks uses the last filtered state for the forecast, different from the 
    iterative schemes which use the once or multiple-times re-analized posterior for
    the initial condition for the forecast of the states to the next shift.

    Optional argument includes state dimension for extended state including parameters.
    In this case, a value for the parameter covariance inflation should be included
    in addition to the state covariance inflation."""
    
    # step 0: unpack kwargs
    f_steps = kwargs["f_steps"]::Int64
    step_model! = kwargs["step_model"]
    posterior = kwargs["posterior"]::Array{Float64,3}
    
    
    # infer the ensemble, obs, and system dimensions,
    # observation sequence includes shift forward times,
    # posterior is size lag + shift
    obs_dim, shift = size(obs)
    sys_dim, N_ens, lag = size(posterior)
    lag = lag - shift

    if shift < lag
        # posterior contains length lag + shift past states, we discard the oldest shift
        # states and load the new filtered states in the routine
        posterior = cat(posterior[:, :, 1 + shift: end], 
                        Array{Float64}(undef, sys_dim, N_ens, shift), dims=3)
    end

    # optional parameter estimation
    if haskey(kwargs, "state_dim")
        state_dim = kwargs["state_dim"]::Int64
        param_infl = kwargs["param_infl"]::Float64
        param_wlk = kwargs["param_wlk"]::Float64
        param_est = true
    else
        state_dim = sys_dim
        param_est = false
    end

    # step 1: create storage for the forecast and filter values over the DAW
    forecast = Array{Float64}(undef, sys_dim, N_ens, shift)
    filtered = Array{Float64}(undef, sys_dim, N_ens, shift)

    # step 2: forward propagate the ensemble and analyze the observations
    for s in 1:shift
        # initialize posterior for the special case lag=shift
        if lag==shift
            posterior[:, :, s] = ens
        end
        
        # step 2a: propagate between observation times
        for j in 1:N_ens
            if param_est
                if string(parentmodule(kwargs["dx_dt"])) == "IEEE39bus"
                    # define the diffusion structure matrix with respect to the sample value
                    # of the inertia, as per each ensemble member
                    diff_mat = zeros(20,20)
                    diff_mat[LinearAlgebra.diagind(diff_mat)[11:end]] =
                    kwargs["dx_params"]["ω"][1] ./ (2.0 * ens[21:30, j])
                    kwargs["diff_mat"] = diff_mat
                end
            end
            @views for k in 1:f_steps
                step_model!(ens[:, j], 0.0, kwargs)
                if string(parentmodule(kwargs["dx_dt"])) == "IEEE39bus"
                    # set phase angles mod 2pi
                    ens[1:10, j] .= rem2pi.(ens[1:10, j], RoundNearest)
                end
            end
        end

        # step 2b: store forecast to compute ensemble statistics before observations
        # become available
        forecast[:, :, s] = ens

        # step 2c: perform the filtering step
        trans = transform(analysis, ens, obs[:, s], obs_cov, kwargs)
        ens_update!(ens, trans)

        # compute multiplicative inflation of state variables
        inflate_state!(ens, state_infl, sys_dim, state_dim)

        # if including an extended state of parameter values,
        # compute multiplicative inflation of parameter values
        if state_dim != sys_dim
            inflate_param!(ens, param_infl, sys_dim, state_dim)
        end

        # store the filtered states and posterior states
        filtered[:, :, s] = ens
        posterior[:, :, end - shift + s] = ens
        
        # step 2e: re-analyze the posterior in the lag window of states,
        # not including current time
        @views for l in 1:lag + s - 1 
            ens_update!(posterior[:, :, l], trans)
        end
    end
            
    # step 3: if performing parameter estimation, apply the parameter model
    if state_dim != sys_dim
        param_ens = ens[state_dim + 1:end , :]
        param_mean = mean(param_ens, dims=2)
        param_ens .= param_ens + 
                     param_wlk * param_mean .* rand(Normal(), length(param_mean), N_ens)
        ens[state_dim + 1:end, :] = param_ens
    end
    
    Dict{String,Array{Float64}}(
                                "ens" => ens, 
                                "post" =>  posterior, 
                                "fore" => forecast, 
                                "filt" => filtered
                               ) 
end

##############################################################################################
# single iteration, correlation-based lag_shift_smoother

function ls_smoother_single_iteration(analysis::String, ens::Array{Float64,2},
                                      obs::Array{Float64,2}, obs_cov::CovM,
                                      state_infl::Float64, kwargs::Dict{String,Any})

    """Lag-shift ensemble kalman smoother analysis step, single iteration version 

    Single-iteration enks uses the final re-analyzed posterior initial state for the forecast,
    which is pushed forward in time to shift-number of observation times.
    Optional argument includes state dimension for an extended state including parameters.
    In this case, a value for the parameter covariance inflation should be included in
    addition to the state covariance inflation."""
    
    # step 0: unpack kwargs, posterior contains length lag past states ending
    # with ens as final entry
    f_steps = kwargs["f_steps"]::Int64
    step_model! = kwargs["step_model"]
    posterior = kwargs["posterior"]::Array{Float64,3}
    
    # infer the ensemble, obs, and system dimensions, observation sequence
    # includes lag forward times
    obs_dim, lag = size(obs)
    sys_dim, N_ens, shift = size(posterior)

    # optional parameter estimation
    if haskey(kwargs, "state_dim")
        state_dim = kwargs["state_dim"]::Int64
        param_infl = kwargs["param_infl"]::Float64
        param_wlk = kwargs["param_wlk"]::Float64
        param_est = true
    else
        state_dim = sys_dim
        param_est = false
    end

    # make a copy of the intial ens for re-analysis
    ens_0 = copy(ens)
    
    # spin to be used on the first lag-assimilations -- this makes the smoothed time-zero
    # re-analized prior the first initial condition for the future iterations
    # regardless of sda or mda settings
    spin = kwargs["spin"]::Bool
    
    # step 1: create storage for the posterior, forecast and filter values over the DAW
    # only the shift-last and shift-first values are stored as these represent the
    # newly forecasted values and last-iterate posterior estimate respectively
    if spin
        forecast = Array{Float64}(undef, sys_dim, N_ens, lag)
        filtered = Array{Float64}(undef, sys_dim, N_ens, lag)
    else
        forecast = Array{Float64}(undef, sys_dim, N_ens, shift)
        filtered = Array{Float64}(undef, sys_dim, N_ens, shift)
    end
    
    # multiple data assimilation (mda) is optional, read as boolean variable
    mda = kwargs["mda"]::Bool
    
    if mda
        # set the observation and re-balancing weights
        reb_weights = kwargs["reb_weights"]::Vector{Float64}
        obs_weights = kwargs["obs_weights"]::Vector{Float64}

        # set iteration count for the initial rebalancing step followed by mda
        i = 0
        
        # the posterior statistics are computed in the zeroth pass with rebalancing
        posterior[:, :, 1] = ens_0
        
        # make a single iteration with SDA,
        # with MDA make a rebalancing step on the zeroth iteration
        while i <=1 
            # step 2: forward propagate the ensemble and analyze the observations
            for l in 1:lag
                # step 2a: propagate between observation times
                for j in 1:N_ens
                    if param_est
                        if string(parentmodule(kwargs["dx_dt"])) == "IEEE39bus"
                            # define the structure matrix with respect to the sample value
                            # of the inertia, as per each ensemble member
                            diff_mat = zeros(20,20)
                            diff_mat[LinearAlgebra.diagind(diff_mat)[11:end]] =
                            kwargs["dx_params"]["ω"][1] ./ (2.0 * ens[21:30, j])
                            kwargs["diff_mat"] = diff_mat
                        end
                    end
                    @views for k in 1:f_steps
                        step_model!(ens[:, j], 0.0, kwargs)
                        if string(parentmodule(kwargs["dx_dt"])) == "IEEE39bus"
                            # set phase angles mod 2pi
                            ens[1:10, j] .= rem2pi.(ens[1:10, j], RoundNearest)
                        end
                    end
                end
                if i == 0
                    # step 2b: store forecast to compute ensemble statistics before
                    # observations become available
                    # for MDA, this is on the zeroth iteration through the DAW
                    if spin
                        # store all new forecast states
                        forecast[:, :, l] = ens
                    elseif (l > (lag - shift))
                        # only store forecasted states for beyond unobserved
                        # times beyond previous forecast windows
                        forecast[:, :, l - (lag - shift)] = ens
                    end
                    
                    # step 2c: perform the filtering step with rebalancing weights 
                    trans = transform(analysis,
                                      ens, obs[:, l], obs_cov * reb_weights[l], kwargs)
                    ens_update!(ens, trans)

                    if spin 
                        # compute multiplicative inflation of state variables
                        inflate_state!(ens, state_infl, sys_dim, state_dim)

                        # if including an extended state of parameter values,
                        # compute multiplicative inflation of parameter values
                        if state_dim != sys_dim
                            inflate_param!(ens, param_infl, sys_dim, state_dim)
                        end
                        
                        # store all new filtered states
                        filtered[:, :, l] = ens
                    
                    elseif l > (lag - shift)
                        # store the filtered states for previously unobserved times,
                        # not mda values
                        filtered[:, :, l - (lag - shift)] = ens
                    end
                    
                    # step 2d: compute re-analyzed posterior statistics within rebalancing
                    # step, using the MDA rebalancing analysis transform for all available
                    # times on all states that will be discarded on the next shift
                    reanalysis_index = min(shift, l)
                    @views for s in 1:reanalysis_index
                        ens_update!(posterior[:, :, s], trans)
                    end
                    
                    # store most recent filtered state in the posterior statistics, for all
                    # states to be discarded on the next shift > 1
                    if l < shift
                        posterior[:, :, l + 1] = ens
                    end
                else
                    # step 2c: perform the filtering step with mda weights
                    trans = transform(analysis,
                                      ens, obs[:, l], obs_cov * obs_weights[l], kwargs)
                    ens_update!(ens, trans)
                    
                    # re-analyzed initial conditions are computed in the mda step
                    ens_update!(ens_0, trans)
                end
            end
            # reset the ensemble with the prior for mda and step forward the iteration count,
            ens = copy(ens_0)
            i+=1
        end
    else
        # step 2: forward propagate the ensemble and analyze the observations
        for l in 1:lag
            # step 2a: propagate between observation times
            for j in 1:N_ens
                if param_est
                    if string(parentmodule(kwargs["dx_dt"])) == "IEEE39bus"
                        # define the structure matrix with respect to the sample value
                        # of the inertia, as per each ensemble member
                        diff_mat = zeros(20,20)
                        diff_mat[LinearAlgebra.diagind(diff_mat)[11:end]] =
                        kwargs["dx_params"]["ω"][1] ./ (2.0 * ens[21:30, j])
                        kwargs["diff_mat"] = diff_mat
                    end
                end
                @views for k in 1:f_steps
                    step_model!(ens[:, j], 0.0, kwargs)
                    if string(parentmodule(kwargs["dx_dt"])) == "IEEE39bus"
                        # set phase angles mod 2pi
                        ens[1:10, j] .= rem2pi.(ens[1:10, j], RoundNearest)
                    end
                end
            end
            if spin
                # step 2b: store forecast to compute ensemble statistics before observations
                # become available
                # if spin, store all new forecast states
                forecast[:, :, l] = ens
                
                # step 2c: apply the transformation and update step
                trans = transform(analysis, ens, obs[:, l], obs_cov, kwargs)
                ens_update!(ens, trans)
                
                # compute multiplicative inflation of state variables
                inflate_state!(ens, state_infl, sys_dim, state_dim)

                # if including an extended state of parameter values,
                # compute multiplicative inflation of parameter values
                if state_dim != sys_dim
                    inflate_param!(ens, param_infl, sys_dim, state_dim)
                end
                
                # store all new filtered states
                filtered[:, :, l] = ens
            
                # step 2d: compute the re-analyzed initial condition if assimilation update
                ens_update!(ens_0, trans)
            
            elseif l > (lag - shift)
                # step 2b: store forecast to compute ensemble statistics before observations
                # become available
                # if not spin, only store forecasted states for beyond unobserved times
                # beyond previous forecast windows
                forecast[:, :, l - (lag - shift)] = ens
                
                # step 2c: apply the transformation and update step
                trans = transform(analysis, ens, obs[:, l], obs_cov, kwargs)
                ens_update!(ens, trans)
                
                # store the filtered states for previously unobserved times, not mda values
                filtered[:, :, l - (lag - shift)] = ens
                
                # step 2d: compute re-analyzed initial condition if assimilation update
                ens_update!(ens_0, trans)
            end
        end
        # reset the ensemble with the re-analyzed prior 
        ens = copy(ens_0)
    end

    # step 3: propagate the posterior initial condition forward to the shift-forward time
    # step 3a: inflate the posterior covariance
    inflate_state!(ens, state_infl, sys_dim, state_dim)
    
    # if including an extended state of parameter values,
    # compute multiplicative inflation of parameter values
    if state_dim != sys_dim
        inflate_param!(ens, param_infl, sys_dim, state_dim)
    end

    # step 3b: if performing parameter estimation, apply the parameter model
    if state_dim != sys_dim
        param_ens = ens[state_dim + 1:end , :]
        param_mean = mean(param_ens, dims=2)
        param_ens .= param_ens +
                     param_wlk * param_mean .* rand(Normal(), length(param_mean), N_ens)
        ens[state_dim + 1:end , :] = param_ens
    end

    # step 3c: propagate the re-analyzed, resampled-in-parameter-space ensemble up by shift
    # observation times
    for s in 1:shift
        if !mda
            posterior[:, :, s] = ens
        end
        for j in 1:N_ens
            if param_est
                if string(parentmodule(kwargs["dx_dt"])) == "IEEE39bus"
                    # define the diffusion structure matrix with respect to the sample value
                    # of the inertia, as per each ensemble member
                    diff_mat = zeros(20,20)
                    diff_mat[LinearAlgebra.diagind(diff_mat)[11:end]] =
                    kwargs["dx_params"]["ω"][1] ./ (2.0 * ens[21:30, j])
                    kwargs["diff_mat"] = diff_mat
                end
            end
            @views for k in 1:f_steps
                step_model!(ens[:, j], 0.0, kwargs)
                if string(parentmodule(kwargs["dx_dt"])) == "IEEE39bus"
                    # set phase angles mod 2pi
                    ens[1:10, j] .= rem2pi.(ens[1:10, j], RoundNearest)
                end
            end
        end
    end

    Dict{String,Array{Float64}}(
                                "ens" => ens, 
                                "post" =>  posterior, 
                                "fore" => forecast, 
                                "filt" => filtered,
                                ) 
end


##############################################################################################

function ls_smoother_gauss_newton(analysis::String, ens::Array{Float64,2},
                                  obs::Array{Float64,2}, obs_cov::CovM, state_infl::Float64,
                                  kwargs::Dict{String,Any}; ϵ::Float64=0.0001,
                                  tol::Float64=0.001, max_iter::Int64=5)


    """Lag-shift Gauss-Newton IEnKS analysis step, algorithm 4, Bocquet & Sakov 2014

    ienks uses the final re-analyzed posterior initial state for the forecast, 
    which is pushed forward in time from the initial conidtion to shift-number of observation
    times.

    Optional argument includes state dimension for an extended state including parameters.
    In this case, a value for the parameter covariance inflation should be included
    in addition to the state covariance inflation."""
    
    # step 0: unpack kwargs, posterior contains length lag past states ending
    # with ens as final entry
    f_steps = kwargs["f_steps"]::Int64
    step_model! = kwargs["step_model"]
    posterior = kwargs["posterior"]::Array{Float64,3}
    
    # infer the ensemble, obs, and system dimensions,
    # observation sequence includes lag forward times
    obs_dim, lag = size(obs)
    sys_dim, N_ens, shift = size(posterior)

    # optional parameter estimation
    if haskey(kwargs, "state_dim")
        state_dim = kwargs["state_dim"]::Int64
        param_infl = kwargs["param_infl"]::Float64
        param_wlk = kwargs["param_wlk"]::Float64
        param_est = true
    else
        state_dim = sys_dim
        param_est = false
    end

    # spin to be used on the first lag-assimilations -- this makes the smoothed time-zero
    # re-analized prior
    # the first initial condition for the future iterations regardless of sda or mda settings
    spin = kwargs["spin"]::Bool
    
    # step 1: create storage for the posterior filter values over the DAW, 
    # forecast values in the DAW+shift
    if spin
        forecast = Array{Float64}(undef, sys_dim, N_ens, lag + shift)
        filtered = Array{Float64}(undef, sys_dim, N_ens, lag)
    else
        forecast = Array{Float64}(undef, sys_dim, N_ens, shift)
        filtered = Array{Float64}(undef, sys_dim, N_ens, shift)
    end

    # step 1a: determine if using finite-size or MDA formalism in the below
    if analysis[1:7] == "ienks-n"
        # epsilon inflation factor corresponding to unknown forecast distribution mean
        ϵ_N = 1.0 + (1.0 / N_ens)

        # effective ensemble size
        N_effective = N_ens + 1.0
    end

    # multiple data assimilation (mda) is optional, read as boolean variable
    mda = kwargs["mda"]::Bool
    
    # algorithm splits on the use of MDA or not
    if mda
        # 1b: define the initial parameters for the two stage iterative optimization

        # define the rebalancing weights for the first sweep of the algorithm
        reb_weights = kwargs["reb_weights"]::Vector{Float64}

        # define the mda weights for the second pass of the algorithm
        obs_weights = kwargs["obs_weights"]::Vector{Float64}

        # m gives the total number of iterations of the algorithm over both the
        # rebalancing and the MDA steps, this is combined from the iteration count
        # i in each stage; the iterator i will give the number of iterations of the 
        # optimization and does not take into account the forecast / filtered iteration; 
        # for an optmized routine of the transform version, forecast / filtered statistics 
        # can be computed within the iteration count i; for the optimized bundle 
        # version, forecast / filtered statistics need to be computed with an additional 
        # iteration due to the epsilon scaling of the ensemble
        m = 0

        # stage gives the algorithm stage, 0 is rebalancing, 1 is MDA
        stage = 0

        # step 1c: compute the initial ensemble mean and normalized anomalies, 
        # and storage for the sequentially computed iterated mean, gradient 
        # and hessian terms 
        ens_mean_0 = mean(ens, dims=2)
        anom_0 = ens .- ens_mean_0 

        ∇J = Array{Float64}(undef, N_ens, lag)
        hess_J = Array{Float64}(undef, N_ens, N_ens, lag)

        # pre-allocate these variables as global for the loop re-definitions
        hessian = Symmetric(Array{Float64}(undef, N_ens, N_ens))
        new_ens = Array{Float64}(undef, sys_dim, N_ens)
        
        # step through two stages starting at zero
        while stage <=1
            # step 1d: (re)-define the conditioning for bundle versus transform varaints
            if analysis[end-5:end] == "bundle"
                T = ϵ*I
                T_inv = (1.0 / ϵ)*I
            elseif analysis[end-8:end] == "transform"
                T = 1.0*I
                T_inv = 1.0*I
            end

            # step 1e: (re)define the iteration count and the base-point for the optimization
            i = 0
            ens_mean_iter = copy(ens_mean_0) 
            w = zeros(N_ens)
            
            # step 2: begin iterative optimization
            while i < max_iter 
                # step 2a: redefine the conditioned ensemble with updated mean, after 
                # first spin run in stage 0 
                if !spin || i > 0 || stage > 0
                    ens = ens_mean_iter .+ anom_0 * T
                end

                # step 2b: forward propagate the ensemble and sequentially store the 
                # forecast or construct cost function
                for l in 1:lag
                    # propagate between observation times
                    for j in 1:N_ens
                        if param_est
                            if string(parentmodule(kwargs["dx_dt"])) == "IEEE39bus"
                                # define structure matrix with respect to the sample value
                                # of the inertia, as per each ensemble member
                                diff_mat = zeros(20,20)
                                diff_mat[LinearAlgebra.diagind(diff_mat)[11:end]] =
                                kwargs["dx_params"]["ω"][1] ./ (2.0 * ens[21:30, j])
                                kwargs["diff_mat"] = diff_mat
                            end
                        end
                        @views for k in 1:f_steps
                            step_model!(ens[:, j], 0.0, kwargs)
                            if string(parentmodule(kwargs["dx_dt"])) == "IEEE39bus"
                                # set phase angles mod 2pi
                                ens[1:10, j] .= rem2pi.(ens[1:10, j], RoundNearest)
                            end
                        end
                    end

                    if spin && i == 0 && stage==0
                        # if first spin, store the forecast over the entire DAW
                        forecast[:, :, l] = ens

                    # otherwise, compute the sequential terms of the gradient and hessian of 
                    # the cost function, weights depend on the stage of the algorithm
                    elseif stage == 0 
                        # this is the rebalancing step to produce filter and forecast stats
                        ∇J[:,l], hess_J[:, :, l] = transform(
                                                             analysis,
                                                             ens, obs[:, l],
                                                             obs_cov * reb_weights[l], 
                                                             kwargs,
                                                             conditioning=T_inv
                                                            )

                    elseif stage == 1
                        # this is the MDA step to shift the window forward
                        ∇J[:,l], hess_J[:, :, l] = transform(
                                                             analysis,
                                                             ens,
                                                             obs[:, l],
                                                             obs_cov * obs_weights[l], 
                                                             kwargs,
                                                             conditioning=T_inv
                                                            )
                    end

                end

                # skip this section in the first spin cycle, return and begin optimization
                if !spin || i > 0 || stage > 0
                    # step 2c: formally compute the gradient and the hessian from the 
                    # sequential components, perform Gauss-Newton after forecast iteration
                    if analysis[1:7] == "ienks-n" 
                        # use the finite size EnKF cost function for the gradient calculation 
                        ζ = 1.0 / (sum(w.^2.0) + ϵ_N)
                        gradient = N_effective * ζ * w - sum(∇J, dims=2)

                        # hessian is computed with the effective ensemble size
                        hessian = Symmetric((N_effective - 1.0) * I +
                                            dropdims(sum(hess_J, dims=3), dims=3))
                    else
                        # compute the usual cost function directly
                        gradient = (N_ens - 1.0) * w - sum(∇J, dims=2)

                        # hessian is computed with the ensemble rank
                        hessian = Symmetric((N_ens - 1.0) * I +
                                            dropdims(sum(hess_J, dims=3), dims=3))
                    end

                    if analysis[end-8:end] == "transform"
                        # transform method requires each of the below, and we make 
                        # all calculations simultaneously via the SVD for stability
                        T, T_inv, hessian_inv = square_root_inv(hessian, full=true)
                        
                        # compute the weights update
                        Δw = hessian_inv * gradient
                    else
                        # compute the weights update by the standard linear equation solver
                        Δw = hessian \ gradient
                    end

                    # update the weights
                    w -= Δw 

                    # update the mean via the increment, always with the zeroth 
                    # iterate of the ensemble
                    ens_mean_iter = ens_mean_0 + anom_0 * w
                    
                    if norm(Δw) < tol
                        i+=1
                        break
                    end
                end
                
                # update the iteration count
                i+=1
            end

            # step 3: compute posterior initial condiiton and propagate forward in time
            # step 3a: perform the analysis of the ensemble
            if analysis[1:7] == "ienks-n" 
                # use finite size EnKF cost function to produce adaptive
                # inflation with the hessian
                ζ = 1.0 / (sum(w.^2.0) + ϵ_N)
                hessian = Symmetric(
                                    N_effective * (ζ * I - 2.0 * ζ^(2.0) * w * transpose(w)) +
                                    dropdims(sum(hess_J, dims=3), dims=3)
                                   )
                T = square_root_inv(hessian)
            elseif analysis == "ienks-bundle"
                T = square_root_inv(hessian)
            end
            # compute analyzed ensemble by the iterated mean and the transformed
            # original anomalies
            U = rand_orth(N_ens)
            ens = ens_mean_iter .+ sqrt(N_ens - 1.0) * anom_0 * T * U

            # step 3b: if performing parameter estimation, apply the parameter model
            # for the for the MDA step and shifted window
            if state_dim != sys_dim && stage == 1
                param_ens = ens[state_dim + 1:end , :]
                param_mean = mean(param_ens, dims=2)
                param_ens .= param_ens +
                             param_wlk *
                             param_mean .* rand(Normal(), length(param_mean), N_ens)
                ens[state_dim + 1:end, :] = param_ens
            end

            # step 3c: propagate the re-analyzed, resampled-in-parameter-space ensemble up 
            # by shift observation times in stage 1, store the filtered state as the forward 
            # propagated value at the new observation times within the DAW in stage 0, 
            # the forecast states as those beyond the DAW in stage 0, and
            # store the posterior at the times discarded at the next shift in stage 0
            if stage == 0
                for l in 1:lag + shift
                    if l <= shift
                        # store the posterior ensemble at times that will be discarded
                        posterior[:, :, l] = ens
                    end

                    # shift the ensemble forward Δt
                    for j in 1:N_ens
                        if param_est
                            if string(parentmodule(kwargs["dx_dt"])) == "IEEE39bus"
                                # define structure matrix with respect to the sample value
                                # of the inertia, as per each ensemble member
                                diff_mat = zeros(20,20)
                                diff_mat[LinearAlgebra.diagind(diff_mat)[11:end]] =
                                kwargs["dx_params"]["ω"][1] ./ (2.0 * ens[21:30, j])
                                kwargs["diff_mat"] = diff_mat
                            end
                        end
                        @views for k in 1:f_steps
                            step_model!(ens[:, j], 0.0, kwargs)
                            if string(parentmodule(kwargs["dx_dt"])) == "IEEE39bus"
                                # set phase angles mod 2pi
                                ens[1:10, j] .= rem2pi.(ens[1:10, j], RoundNearest)
                            end
                        end
                    end

                    if spin && l <= lag
                        # store spin filtered states at all times up to lag
                        filtered[:, :, l] = ens
                    elseif spin && l > lag
                        # store the remaining spin forecast states at shift times
                        # beyond the DAW
                        forecast[:, :, l] = ens
                    elseif l > lag - shift && l <= lag
                        # store filtered states for newly assimilated observations
                        filtered[:, :, l - (lag - shift)] = ens
                    elseif l > lag
                        # store forecast states at shift times beyond the DAW
                        forecast[:, :, l - lag] = ens
                    end
                end
            else
                for l in 1:shift
                    for j in 1:N_ens
                        @views for k in 1:f_steps
                            step_model!(ens[:, j], 0.0, kwargs)
                            if string(parentmodule(kwargs["dx_dt"])) == "IEEE39bus"
                                # set phase angles mod 2pi
                                ens[1:10, j] .= rem2pi.(ens[1:10, j], RoundNearest)
                            end
                        end
                    end
                end
            end
            stage += 1
            m += i
        end
        
        # store and inflate the forward posterior at the new initial condition
        inflate_state!(ens, state_infl, sys_dim, state_dim)

        # if including an extended state of parameter values,
        # compute multiplicative inflation of parameter values
        if state_dim != sys_dim
            inflate_param!(ens, param_infl, sys_dim, state_dim)
        end

        Dict{String,Array{Float64}}(
                                    "ens" => ens, 
                                    "post" =>  posterior, 
                                    "fore" => forecast, 
                                    "filt" => filtered,
                                    "iterations" => Array{Float64}([m])
                                   ) 
    else
        # step 1b: define the initial correction and iteration count, note that i will
        # give the number of iterations of the optimization and does not take into
        # account the forecast / filtered iteration; for an optmized routine of the
        # transform version, forecast / filtered statistics can be computed within
        # the iteration count i; for the optimized bundle version, forecast / filtered
        # statistics need to be computed with an additional iteration due to the epsilon
        # scaling of the ensemble
        w = zeros(N_ens)
        i = 0

        # step 1c: compute the initial ensemble mean and normalized anomalies, 
        # and storage for the  sequentially computed iterated mean, gradient 
        # and hessian terms 
        ens_mean_0 = mean(ens, dims=2)
        ens_mean_iter = copy(ens_mean_0) 
        anom_0 = ens .- ens_mean_0 

        if spin 
            ∇J = Array{Float64}(undef, N_ens, lag)
            hess_J = Array{Float64}(undef, N_ens, N_ens, lag)
        else
            ∇J = Array{Float64}(undef, N_ens, shift)
            hess_J = Array{Float64}(undef, N_ens, N_ens, shift)
        end

        # pre-allocate these variables as global for the loop re-definitions
        hessian = Symmetric(Array{Float64}(undef, N_ens, N_ens))
        new_ens = Array{Float64}(undef, sys_dim, N_ens)

        # step 1e: define the conditioning for bundle versus transform varaints
        if analysis[end-5:end] == "bundle"
            T = ϵ*I
            T_inv = (1.0 / ϵ)*I
        elseif analysis[end-8:end] == "transform"
            T = 1.0*I
            T_inv = 1.0*I
        end

        # step 2: begin iterative optimization
        while i < max_iter 
            # step 2a: redefine the conditioned ensemble with updated mean, after the 
            # first spin run or for all runs if after the spin cycle
            if !spin || i > 0 
                ens = ens_mean_iter .+ anom_0 * T
            end

            # step 2b: forward propagate the ensemble and sequentially store the forecast 
            # or construct cost function
            for l in 1:lag
                # propagate between observation times
                for j in 1:N_ens
                    if param_est
                        if string(parentmodule(kwargs["dx_dt"])) == "IEEE39bus"
                            # define structure matrix with respect to the sample value
                            # of the inertia, as per each ensemble member
                            diff_mat = zeros(20,20)
                            diff_mat[LinearAlgebra.diagind(diff_mat)[11:end]] =
                            kwargs["dx_params"]["ω"][1] ./ (2.0 * ens[21:30, j])
                            kwargs["diff_mat"] = diff_mat
                        end
                    end
                    @views for k in 1:f_steps
                        step_model!(ens[:, j], 0.0, kwargs)
                        if string(parentmodule(kwargs["dx_dt"])) == "IEEE39bus"
                            # set phase angles mod 2pi
                            ens[1:10, j] .= rem2pi.(ens[1:10, j], RoundNearest)
                        end
                    end
                end
                if spin
                    if i == 0
                       # if first spin, store the forecast over the entire DAW
                       forecast[:, :, l] = ens
                    else
                        # otherwise, compute the sequential terms of the gradient
                        # and hessian of the cost function over all observations in the DAW
                        ∇J[:,l], hess_J[:, :, l] = transform(
                                                             analysis,
                                                             ens,
                                                             obs[:, l],
                                                             obs_cov,
                                                             kwargs,
                                                             conditioning=T_inv
                                                            )
                    end
                elseif l > (lag - shift)
                    # compute sequential terms of the gradient and hessian of the
                    # cost function only for the shift-length new observations in the DAW 
                    ∇J[:,l - (lag - shift)], 
                    hess_J[:, :, l - (lag - shift)] = transform(
                                                                analysis,
                                                                ens,
                                                                obs[:, l],
                                                                obs_cov,
                                                                kwargs,
                                                                conditioning=T_inv
                                                               )
                end
            end

            # skip this section in the first spin cycle, return and begin optimization
            if !spin || i > 0
                # step 2c: otherwise, formally compute the gradient and the hessian from the 
                # sequential components, perform Gauss-Newton step after forecast iteration
                if analysis[1:7] == "ienks-n" 
                    # use finite size EnKF cost function to produce the gradient calculation 
                    ζ = 1.0 / (sum(w.^2.0) + ϵ_N)
                    gradient = N_effective * ζ * w - sum(∇J, dims=2)

                    # hessian is computed with the effective ensemble size
                    hessian = Symmetric((N_effective - 1.0) * I +
                                        dropdims(sum(hess_J, dims=3), dims=3))
                else
                    # compute the usual cost function directly
                    gradient = (N_ens - 1.0) * w - sum(∇J, dims=2)

                    # hessian is computed with the ensemble rank
                    hessian = Symmetric((N_ens - 1.0) * I +
                                        dropdims(sum(hess_J, dims=3), dims=3))
                end
                if analysis[end-8:end] == "transform"
                    # transform method requires each of the below, and we make 
                    # all calculations simultaneously via the SVD for stability
                    T, T_inv, hessian_inv = square_root_inv(hessian, full=true)
                    
                    # compute the weights update
                    Δw = hessian_inv * gradient
                else
                    # compute the weights update by the standard linear equation solver
                    Δw = hessian \ gradient

                end

                # update the weights
                w -= Δw 

                # update the mean via the increment, always with the zeroth iterate 
                # of the ensemble
                ens_mean_iter = ens_mean_0 + anom_0 * w
                
                if norm(Δw) < tol
                    i +=1
                    break
                end
            end
            
            # update the iteration count
            i+=1
        end
        # step 3: compute posterior initial condiiton and propagate forward in time
        # step 3a: perform the analysis of the ensemble
        if analysis[1:7] == "ienks-n" 
            # use finite size EnKF cost function to produce adaptive inflation
            # with the hessian
            ζ = 1.0 / (sum(w.^2.0) + ϵ_N)
            hessian = Symmetric(
                                N_effective * (ζ * I - 2.0 * ζ^(2.0) * w * transpose(w)) + 
                                dropdims(sum(hess_J, dims=3), dims=3)
                               )
            
            # redefine the ensemble transform for the final update
            T = square_root_inv(hessian)

        elseif analysis == "ienks-bundle"
            # redefine the ensemble transform for the final update,
            # this is already computed in-loop for the ienks-transform
            T = square_root_inv(hessian)
        end

        # compute analyzed ensemble by the iterated mean and the transformed
        # original anomalies
        U = rand_orth(N_ens)
        ens = ens_mean_iter .+ sqrt(N_ens - 1.0) * anom_0 * T * U

        # step 3b: if performing parameter estimation, apply the parameter model
        if state_dim != sys_dim
            param_ens = ens[state_dim + 1:end , :]
            param_ens = param_ens + param_wlk * rand(Normal(), size(param_ens))
            ens[state_dim + 1:end, :] = param_ens
        end

        # step 3c: propagate re-analyzed, resampled-in-parameter-space ensemble up by shift
        # observation times, store the filtered state as the forward propagated value at the 
        # new observation times within the DAW, forecast states as those beyond the DAW, and
        # store the posterior at the times discarded at the next shift
        for l in 1:lag + shift
            if l <= shift
                # store the posterior ensemble at times that will be discarded
                posterior[:, :, l] = ens
            end

            # shift the ensemble forward Δt
            for j in 1:N_ens
                if param_est
                    if string(parentmodule(kwargs["dx_dt"])) == "IEEE39bus"
                        # define structure matrix with respect to the sample value
                        # of the inertia, as per each ensemble member
                        diff_mat = zeros(20,20)
                        diff_mat[LinearAlgebra.diagind(diff_mat)[11:end]] =
                        kwargs["dx_params"]["ω"][1] ./ (2.0 * ens[21:30, j])
                        kwargs["diff_mat"] = diff_mat
                    end
                end
                @views for k in 1:f_steps
                    step_model!(ens[:, j], 0.0, kwargs)
                    if string(parentmodule(kwargs["dx_dt"])) == "IEEE39bus"
                        # set phase angles mod 2pi
                        ens[1:10, j] .= rem2pi.(ens[1:10, j], RoundNearest)
                    end
                end
            end

            if l == shift
                # store the shift-forward ensemble for the initial condition in the new DAW
                new_ens = copy(ens)
            end

            if spin && l <= lag
                # store spin filtered states at all times up to lag
                filtered[:, :, l] = ens
            elseif spin && l > lag
                # store the remaining spin forecast states at shift times beyond the DAW
                forecast[:, :, l] = ens
            elseif l > lag - shift && l <= lag
                # store filtered states for newly assimilated observations
                filtered[:, :, l - (lag - shift)] = ens
            elseif l > lag
                # store forecast states at shift times beyond the DAW
                forecast[:, :, l - lag] = ens
            end
        end
        
        # store and inflate the forward posterior at the new initial condition
        ens = copy(new_ens)
        inflate_state!(ens, state_infl, sys_dim, state_dim)

        # if including an extended state of parameter values,
        # compute multiplicative inflation of parameter values
        if state_dim != sys_dim
            inflate_param!(ens, param_infl, sys_dim, state_dim)
        end

        Dict{String,Array{Float64}}(
                                    "ens" => ens, 
                                    "post" =>  posterior, 
                                    "fore" => forecast, 
                                    "filt" => filtered,
                                    "iterations" => Array{Float64}([i])
                                   ) 
    end
end


##############################################################################################
# end module

end
##############################################################################################
# Methods below are yet to be to debugged and benchmark
##############################################################################################
# single iteration, correlation-based lag_shift_smoother, adaptive inflation STILL DEBUGGING
#
#function ls_smoother_single_iteration_adaptive(analysis::String, ens::Array{Float64,2}, obs::Array{Float64,2}, 
#                             obs_cov::CovM, state_infl::Float64, kwargs::Dict{String,Any})
#
#    """Lag-shift ensemble kalman smoother analysis step, single iteration adaptive version
#
#    This version of the lag-shift enks uses the final re-analyzed posterior initial state for the forecast, 
#    which is pushed forward in time from the initial conidtion to shift-number of observation times.
#
#    Optional keyword argument includes state dimension if there is an extended state including parameters.  In this
#    case, a value for the parameter covariance inflation should be included in addition to the state covariance
#    inflation. If the analysis method is 'etks_adaptive', this utilizes the past analysis means to construct an 
#    innovation-based estimator for the model error covariances.  This is formed by the expectation step in the
#    expectation maximization algorithm dicussed by Tandeo et al. 2021."""
#    
#    # step 0: unpack kwargs, posterior contains length lag past states ending with ens as final entry
#    f_steps = kwargs["f_steps"]::Int64
#    step_model! = kwargs["step_model"]
#    posterior = kwargs["posterior"]::Array{Float64,3}
#    
#    # infer the ensemble, obs, and system dimensions, observation sequence includes lag forward times
#    obs_dim, lag = size(obs)
#    sys_dim, N_ens, shift = size(posterior)
#
#    # for the adaptive inflation shceme
#    # load bool if spinning up tail of innovation statistics
#    tail_spin = kwargs["tail_spin"]::Bool
#
#    # pre_analysis will contain the sequence of the last cycle's analysis states 
#    # over the current DAW 
#    pre_analysis = kwargs["analysis"]::Array{Float64,3}
#
#    # analysis innovations contains the innovation statistics over the previous DAW plus a trail of
#    # length tail * lag to ensure more robust frequentist estimates
#    analysis_innovations = kwargs["analysis_innovations"]::Array{Float64,2}
#
#    # optional parameter estimation
#    if haskey(kwargs, "state_dim")
#        state_dim = kwargs["state_dim"]::Int64
#        param_infl = kwargs["param_infl"]::Float64
#        param_wlk = kwargs["param_wlk"]::Float64
#
#    else
#        state_dim = sys_dim
#    end
#
#    # make a copy of the intial ens for re-analysis
#    ens_0 = copy(ens)
#    
#    # spin to be used on the first lag-assimilations -- this makes the smoothed time-zero re-analized prior
#    # the first initial condition for the future iterations regardless of sda or mda settings
#    spin = kwargs["spin"]::Bool
#    
#    # step 1: create storage for the posterior, forecast and filter values over the DAW
#    # only the shift-last and shift-first values are stored as these represent the newly forecasted values and
#    # last-iterate posterior estimate respectively
#    if spin
#        forecast = Array{Float64}(undef, sys_dim, N_ens, lag)
#        filtered = Array{Float64}(undef, sys_dim, N_ens, lag)
#    else
#        forecast = Array{Float64}(undef, sys_dim, N_ens, shift)
#        filtered = Array{Float64}(undef, sys_dim, N_ens, shift)
#    end
#    
#    if spin
#        ### NOTE: WRITING THIS NOW SO THAT WE WILL HAVE AN ARBITRARY TAIL OF INNOVATION STATISTICS
#        # FROM THE PASS BACK THROUGH THE WINDOW, BUT WILL COMPUTE INNOVATIONS ONLY ON THE NEW 
#        # SHIFT-LENGTH REANALYSIS STATES BY THE SHIFTED DAW
#        # create storage for the analysis means computed at each forward step of the current DAW
#        post_analysis = Array{Float64}(undef, sys_dim, N_ens, lag)
#    else
#        # create storage for the analysis means computed at the shift forward states in the DAW 
#        post_analysis = Array{Float64}(undef, sys_dim, N_ens, shift)
#    end
#    
#    # step 2: forward propagate the ensemble and analyze the observations
#    for l in 1:lag
#        # step 2a: propagate between observation times
#        for j in 1:N_ens
#            @views for k in 1:f_steps
#                step_model!(ens[:, j], 0.0, kwargs)
#            end
#        end
#        if spin
#            # step 2b: store the forecast to compute ensemble statistics before observations become available
#            # if spin, store all new forecast states
#            forecast[:, :, l] = ens
#            
#            # step 2c: apply the transformation and update step
#            trans = transform(analysis, ens,  obs[:, l], obs_cov, kwargs)
#            ens_update!(ens, trans)
#            
#            # compute multiplicative inflation of state variables
#            inflate_state!(ens, state_infl, sys_dim, state_dim)
#
#            # if including an extended state of parameter values,
#            # compute multiplicative inflation of parameter values
#            if state_dim != sys_dim
#                inflate_param!(ens, param_infl, sys_dim, state_dim)
#            end
#            
#            # store all new filtered states
#            filtered[:, :, l] = ens
#        
#            # store the re-analyzed ensembles for future statistics
#            post_analysis[:, :, l] = ens
#            for j in 1:l-1
#                post_analysis[:, :, j] = ens_update!(post_analysis[:, :, j], trans)
#            end
#
#            # step 2d: compute the re-analyzed initial condition if we have an assimilation update
#            ens_update!(ens_0, trans)
#        
#        elseif l > (lag - shift)
#            # step 2b: store the forecast to compute ensemble statistics before observations become available
#            # if not spin, only store forecasted states for beyond unobserved times beyond previous forecast windows
#            forecast[:, :, l - (lag - shift)] = ens
#            
#            # step 2c: apply the transformation and update step
#            if tail_spin
#                trans = transform(analysis, ens, obs[:, l], obs_cov, kwargs, 
#                                  m_err=analysis_innovations[:, 1:end-shift])
#            else
#                trans = transform(analysis, ens, obs[:, l], obs_cov, kwargs,
#                                  m_err=analysis_innovations)
#            end
#
#            ens = ens_update!(ens, trans)
#            
#            # store the filtered states for previously unobserved times, not mda values
#            filtered[:, :, l - (lag - shift)] = ens
#            
#            # store the re-analyzed ensembles for future statistics
#            post_analysis[:, :, l] = ens
#            for j in 1:l-1
#                post_analysis[:, :, j] = ens_update!(post_analysis[:, :, j], trans)
#            end
#
#            # step 2d: compute the re-analyzed initial condition if we have an assimilation update
#            ens_update!(ens_0, trans)
#
#        elseif l > (lag - 2 * shift)
#            # store the re-analyzed ensembles for future statistics
#            post_analysis[:, :, l] = ens
#
#            # compute the innovation versus the last cycle's analysis state
#            analysis_innovations[:, :, end - lag + l] = pre_analysis[:, :, l + shift] - post_analysis[:, :, l]
#        end
#    end
#    # reset the ensemble with the re-analyzed prior 
#    ens = copy(ens_0)
#
#    # reset the analysis innovations for the next DAW
#    pre_analysis = copy(post_analysis)
#    
#    if !tail_spin 
#        # add the new shifted DAW innovations to the statistics and discard the oldest
#        # shift-innovations
#        analysis_innovations = hcat(analysis_innovations[:, shift + 1: end],
#                                    Array{Float64}(undef, sys_dim, shift))
#    end
#
#    # step 3: propagate the posterior initial condition forward to the shift-forward time
#    # step 3a: inflate the posterior covariance
#    inflate_state!(ens, state_infl, sys_dim, state_dim)
#    
#    # if including an extended state of parameter values,
#    # compute multiplicative inflation of parameter values
#    if state_dim != sys_dim
#        inflate_param!(ens, param_infl, sys_dim, state_dim)
#    end
#
#    # step 3b: if performing parameter estimation, apply the parameter model
#    if state_dim != sys_dim
#        param_ens = ens[state_dim + 1:end , :]
#        param_ens = param_ens + param_wlk * rand(Normal(), size(param_ens))
#        ens[state_dim + 1:end, :] = param_ens
#    end
#
#    # step 3c: propagate the re-analyzed, resampled-in-parameter-space ensemble up by shift
#    # observation times
#    for s in 1:shift
#        if !mda
#            posterior[:, :, s] = ens
#        end
#        for j in 1:N_ens
#            @views for k in 1:f_steps
#                step_model!(ens[:, j], 0.0, kwargs)
#            end
#        end
#    end
#
#    if tail_spin
#        # prepare storage for the new innovations concatenated to the oldest lag-innovations
#        analysis_innovations = hcat(analysis_innovations, 
#                                    Array{Float64}(undef, sys_dim, shift))
#    else
#        # reset the analysis innovations window to remove the oldest lag-innovations
#        analysis_innovations = hcat(analysis_innovations[:, shift  + 1: end], 
#                                    Array{Float64}(undef, sys_dim, lag))
#    end
#    
#    Dict{String,Array{Float64}}(
#                                "ens" => ens, 
#                                "post" =>  posterior, 
#                                "fore" => forecast, 
#                                "filt" => filtered,
#                                "anal" => pre_analysis,
#                                "inno" => analysis_innovations,
#                               )
#end
#
#
#########################################################################################################################
#########################################################################################################################
# Methods below taken from old python code, yet to completely convert, debug and benchmark
#########################################################################################################################
## IEnKF-T-LM
#
#
#def ietlm(X_ext_ens, H, obs, obs_cov, f_steps, f, h, tau=0.001, e1=0,
#         inflation=1.0, tol=0.001, l_max=40):
#
#    """This produces an analysis ensemble via transform as in algorithm 3, bocquet sakov 2012"""
#
#    # step 0: infer the ensemble, obs, and state dimensions
#    [sys_dim, N_ens] = np.shape(X_ext_ens)
#    obs_dim = len(obs)
#
#    # step 1: we compute the ensemble mean and non-normalized anomalies
#    X_mean_0 = np.mean(X_ext_ens, axis=1)
#    A_t = X_ext_ens.transpose() - X_mean_0
#
#    # step 2: we define the initial iterative minimization parameters
#    l = 0
#    nu = 2
#    w = np.zeros(N_ens)
#    
#    # step 3: update the mean via the w increment
#    X_mean_1 = X_mean_0 + A_t.transpose() @ w
#    X_mean_tmp = copy.copy(X_mean_1)
#
#    # step 4: evolve the ensemble mean forward in time, and transform into observation space
#    for k in range(f_steps):
#        # propagate ensemble mean one step forward
#        X_mean_tmp = l96_rk4_step(X_mean_tmp, h, f)
#
#    # define the observed mean by the propagated mean in the observation space
#    Y_mean = H @ X_mean_tmp
#
#    # step 5: Define the initial transform
#    T = np.eye(N_ens)
#    
#    # step 6: redefine the ensemble with the updated mean and the transform
#    X_ext_ens = (X_mean_1 + T @ A_t).transpose()
#
#    # step 7: loop over the discretization steps between observations to produce a forecast ensemble
#    for k in range(f_steps):
#        X_ext_ens = l96_rk4_stepV(X_ext_ens, h, f)
#
#    # step 8: compute the forecast anomalies in the observation space, via the observed, evolved mean and the 
#    # observed, forward ensemble, conditioned by the transform
#    Y_ens = H @ X_ext_ens
#    Y_ens_t = np.linalg.inv(T).transpose() @ (Y_ens.transpose() - Y_mean) 
#
#    # step 9: compute the cost function in ensemble space
#    J = 0.5 * (obs - Y_mean) @ np.linalg.inv(obs_cov) @ (obs - Y_mean) + 0.5 * (N_ens - 1) * w @ w
#    
#    # step 10: compute the approximate gradient of the cost function
#    grad_J = (N_ens - 1) * w - Y_ens_t @ np.linalg.inv(obs_cov) @ (obs - Y_mean)
#
#    # step 11: compute the approximate hessian of the cost function
#    hess = (N_ens - 1) * np.eye(N_ens) + Y_ens_t @  np.linalg.inv(obs_cov) @ Y_ens_t.transpose()
#
#    # step 12: compute the infinity norm of the jacobian and the max of the hessian diagonal
#    flag = np.max(np.abs(grad_J)) > e1
#    mu = tau * np.max(np.diag(hess))
#
#    # step 13: while loop
#    while flag: 
#        if l > l_max:
#            break
#
#        # step 14: set the iteration count forward
#        l+= 1
#        
#        # step 15: solve the system for the w increment update
#        δ_w = solve(hess + mu * np.eye(N_ens),  -1 * grad_J)
#
#        # step 16: check if the increment is sufficiently small to terminate
#        if np.sqrt(δ_w @ δ_w) < tol:
#            # step 17: flag false to terminate
#            flag = False
#
#        # step 18: begin else
#        else:
#            # step 19: reset the ensemble adjustment
#            w_prime = w + δ_w
#            
#            # step 20: reset the initial ensemble with the new adjustment term
#            X_mean_1 = X_mean_0 + A_t.transpose() @ w_prime
#            
#            # step 21: forward propagate the new ensemble mean, and transform into observation space
#            X_mean_tmp = copy.copy(X_mean_1)
#            for k in range(f_steps):
#                X_mean_tmp = l96_rk4_step(X_mean_tmp, h, f)
#            
#            Y_mean = H @ X_mean_tmp
#
#            # steps 22 - 24: define the parameters for the confidence region
#            L = 0.5 * δ_w @ (mu * δ_w - grad_J)
#            J_prime = 0.5 * (obs - Y_mean) @ np.linalg.inv(obs_cov) @ (obs - Y_mean) + 0.5 * (N_ens -1) * w_prime @ w_prime
#            theta = (J - J_prime) / L
#
#            # step 25: evaluate if new correction needed
#            if theta > 0:
#                
#                # steps 26 - 28: update the cost function, the increment, and the past ensemble, conditioned with the
#                # transform
#                J = J_prime
#                w = w_prime
#                X_ext_ens = (X_mean_1 + T.transpose() @ A_t).transpose()
#
#                # step 29: integrate the ensemble forward in time
#                for k in range(f_steps):
#                    X_ext_ens = l96_rk4_stepV(X_ext_ens, h, f)
#
#                # step 30: compute the forward anomlaies in the observation space, by the forward evolved mean and forward evolved
#                # ensemble
#                Y_ens = H @ X_ext_ens
#                Y_ens_t = np.linalg.inv(T).transpose() @ (Y_ens.transpose() - Y_mean)
#
#                # step 31: compute the approximate gradient of the cost function
#                grad_J = (N_ens - 1) * w - Y_ens_t @ np.linalg.inv(obs_cov) @ (obs - Y_mean)
#
#                # step 32: compute the approximate hessian of the cost function
#                hess = (N_ens - 1) * np.eye(N_ens) + Y_ens_t @  np.linalg.inv(obs_cov) @ Y_ens_t.transpose()
#
#                # step 33: define the transform as the inverse square root of the hessian
#                V, Sigma, V_t = np.linalg.svd(hess)
#                T = V @ np.diag( 1 / np.sqrt(Sigma) ) @ V_t
#
#                # steps 34 - 35: compute the tolerance and correction parameters
#                flag = np.max(np.abs(grad_J)) > e1
#                mu = mu * np.max([1/3, 1 - (2 * theta - 1)**3])
#                nu = 2
#
#            # steps 36 - 37: else statement, update mu and nu
#            else:
#                mu = mu * nu
#                nu = nu * 2
#
#            # step 38: end if
#        # step 39: end if
#    # step 40: end while
#
#    # step 41: perform update to the initial mean with the new defined anomaly transform 
#    X_mean_1 = X_mean_0 + A_t.transpose() @ w
#
#    # step 42: define the transform as the inverse square root of the hessian, bundle version only
#    #V, Sigma, V_t = np.linalg.svd(hess)
#    #T = V @ np.diag( 1 / np.sqrt(Sigma) ) @ V_t
#
#    # step 43: compute the updated ensemble by the transform conditioned anomalies and updated mean
#    X_ext_ens = (T.transpose() @ A_t + X_mean_1).transpose()
#    
#    # step 44: forward propagate the ensemble to the observation time 
#    for k in range(f_steps):
#        X_ext_ens = l96_rk4_stepV(X_ext_ens, h, f)
#   
#    # step 45: compute the ensemble with inflation
#    X_mean_2 = np.mean(X_ext_ens, axis=1)
#    A_t = X_ext_ens.transpose() - X_mean_2
#    infl = np.eye(N_ens) * inflation
#    X_ext_ens = (X_mean_2 + infl @  A_t).transpose()
#
#    return X_ext_ens
#
#########################################################################################################################
## IEnKF-B-LM
#
#
#def ieblm(X_ext_ens, H, obs, obs_cov, f_steps, f, h, tau=0.001, e1=0, epsilon=0.0001,
#         inflation=1.0, tol=0.001, l_max=40):
#
#    """This produces an analysis ensemble as in algorithm 3, bocquet sakov 2012"""
#
#    # step 0: infer the ensemble, obs, and state dimensions
#    [sys_dim, N_ens] = np.shape(X_ext_ens)
#    obs_dim = len(obs)
#
#    # step 1: we compute the ensemble mean and non-normalized anomalies
#    X_mean_0 = np.mean(X_ext_ens, axis=1)
#    A_t = X_ext_ens.transpose() - X_mean_0
#
#    # step 2: we define the initial iterative minimization parameters
#    l = 0
#    
#    # NOTE: MARC'S VERSION HAS NU SET TO ONE FIRST AND THEN ITERATES ON THIS IN PRODUCTS
#    # OF TWO    
#    #nu = 2
#    nu = 1
#
#    w = np.zeros(N_ens)
#    
#    # step 3: update the mean via the w increment
#    X_mean_1 = X_mean_0 + A_t.transpose() @ w
#    X_mean_tmp = copy.copy(X_mean_1)
#
#    # step 4: evolve the ensemble mean forward in time, and transform into observation space
#    for k in range(f_steps):
#        X_mean_tmp = l96_rk4_step(X_mean_tmp, h, f)
#
#    Y_mean = H @ X_mean_tmp
#
#    # step 5: Define the initial transform, transform version only
#    # T = np.eye(N_ens)
#    
#    # step 6: redefine the ensemble with the updated mean, rescaling by epsilon
#    X_ext_ens = (X_mean_1 + epsilon * A_t).transpose()
#
#    # step 7: loop over the discretization steps between observations to produce a forecast ensemble
#    for k in range(f_steps):
#        X_ext_ens = l96_rk4_stepV(X_ext_ens, h, f)
#
#    # step 8: compute the anomalies in the observation space, via the observed, evolved mean and the observed, 
#    # forward ensemble, rescaling by epsilon
#    Y_ens = H @ X_ext_ens
#    Y_ens_t = (Y_ens.transpose() - Y_mean) / epsilon
#
#    # step 9: compute the cost function in ensemble space
#    J = 0.5 * (obs - Y_mean) @ np.linalg.inv(obs_cov) @ (obs - Y_mean) + 0.5 * (N_ens - 1) * w @ w
#    
#    # step 10: compute the approximate gradient of the cost function
#    grad_J = (N_ens - 1) * w - Y_ens_t @ np.linalg.inv(obs_cov) @ (obs - Y_mean)
#
#    # step 11: compute the approximate hessian of the cost function
#    hess = (N_ens - 1) * np.eye(N_ens) + Y_ens_t @  np.linalg.inv(obs_cov) @ Y_ens_t.transpose()
#
#    # step 12: compute the infinity norm of the jacobian and the max of the hessian diagonal
#    # NOTE: MARC'S VERSION DOES NOT HAVE A FLAG BASED ON THE INFINITY NORM OF THE GRADIENT
#    # THIS IS ALSO PROBABLY A TRIVIAL FLAG
#    # flag = np.max(np.abs(grad_J)) > e1
#    
#    # NOTE: MARC'S FLAG
#    flag = True
#
#    # NOTE: MARC'S VERSION USES MU=1 IN THE FIRST ITERATION AND NEVER MAKES
#    # THIS DECLARATION IN TERMS OF TAU AND HESS
#    # mu = tau * np.max(np.diag(hess))
#    mu = 1
#    
#    # step 13: while loop
#    while flag: 
#        if l > l_max:
#            print(l)
#            break
#
#        # step 14: set the iteration count forward
#        l+= 1
#        
#        # NOTE: MARC'S RE-DEFINITION OF MU AND NU
#        mu *= nu
#        nu *= 2
#
#        # step 15: solve the system for the w increment update
#        δ_w = solve(hess + mu * np.eye(N_ens),  -1 * grad_J)
#
#        # step 16: check if the increment is sufficiently small to terminate
#        # NOTE: MARC'S VERSION NORMALIZES THE LENGTH RELATIVE TO THE ENSEMBLE SIZE
#        if np.sqrt(δ_w @ δ_w) < tol:
#            # step 17: flag false to terminate
#            flag = False
#            print(l)
#
#        # step 18: begin else
#        else:
#            # step 19: reset the ensemble adjustment
#            w_prime = w + δ_w
#            
#            # step 20: reset the initial ensemble with the new adjustment term
#            X_mean_1 = X_mean_0 + A_t.transpose() @ w_prime
#            
#            # step 21: forward propagate the new ensemble mean, and transform into observation space
#            X_mean_tmp = copy.copy(X_mean_1)
#            for k in range(f_steps):
#                X_mean_tmp = l96_rk4_step(X_mean_tmp, h, f)
#            
#            Y_mean = H @ X_mean_tmp
#
#            # steps 22 - 24: define the parameters for the confidence region
#            L = 0.5 * δ_w @ (mu * δ_w - grad_J)
#            J_prime = 0.5 * (obs - Y_mean) @ np.linalg.inv(obs_cov) @ (obs - Y_mean) + 0.5 * (N_ens -1) * w_prime @ w_prime
#            theta = (J - J_prime) / L
#            
#            # step 25: evaluate if new correction needed
#            if theta > 0:
#                
#                # steps 26 - 28: update the cost function, the increment, and the past ensemble, rescaled with epsilon
#                J = J_prime
#                w = w_prime
#                X_ext_ens = (X_mean_1 + epsilon * A_t).transpose()
#
#                # step 29: integrate the ensemble forward in time
#                for k in range(f_steps):
#                    X_ext_ens = l96_rk4_stepV(X_ext_ens, h, f)
#
#                # step 30: compute the forward anomlaies in the observation space, by the forward evolved mean and forward evolved
#                # ensemble
#                Y_ens = H @ X_ext_ens
#                Y_ens_t = (Y_ens.transpose() - Y_mean) / epsilon
#
#                # step 31: compute the approximate gradient of the cost function
#                grad_J = (N_ens - 1) * w - Y_ens_t @ np.linalg.inv(obs_cov) @ (obs - Y_mean)
#
#                # step 32: compute the approximate hessian of the cost function
#                hess = (N_ens - 1) * np.eye(N_ens) + Y_ens_t @  np.linalg.inv(obs_cov) @ Y_ens_t.transpose()
#
#                # step 33: define the transform as the inverse square root of the hessian, transform version only
#                #V, Sigma, V_t = np.linalg.svd(hess)
#                #T = V @ np.diag( 1 / np.sqrt(Sigma) ) @ V_t
#
#                # steps 34 - 35: compute the tolerance and correction parameters
#                # NOTE: TRIVIAL FLAG?
#                # flag = np.max(np.abs(grad_J)) > e1
#                
#                mu = mu * np.max([1/3, 1 - (2 * theta - 1)**3])
#                
#                # NOTE: ADJUSTMENT HERE TO MATCH NU TO MARC'S CODE
#                # nu = 2
#                nu = 1
#
#            # steps 36 - 37: else statement, update mu and nu
#            #else:
#            #    mu = mu * nu
#            #    nu = nu * 2
#
#            # step 38: end if
#        # step 39: end if
#    # step 40: end while
#    
#    # step 41: perform update to the initial mean with the new defined anomaly transform 
#    X_mean_1 = X_mean_0 + A_t.transpose() @ w
#
#    # step 42: define the transform as the inverse square root of the hessian
#    V, Sigma, V_t = np.linalg.svd(hess)
#    T = V @ np.diag( 1 / np.sqrt(Sigma) ) @ V_t
#
#    # step 43: compute the updated ensemble by the transform conditioned anomalies and updated mean
#    X_ext_ens = (T.transpose() @ A_t + X_mean_1).transpose()
#    
#    # step 44: forward propagate the ensemble to the observation time 
#    for k in range(f_steps):
#        X_ext_ens = l96_rk4_stepV(X_ext_ens, h, f)
#    
#    # step 45: compute the ensemble with inflation
#    X_mean_2 = np.mean(X_ext_ens, axis=1)
#    A_t = X_ext_ens.transpose() - X_mean_2
#    infl = np.eye(N_ens) * inflation
#    X_ext_ens = (X_mean_2 + infl @  A_t).transpose()
#
#    return X_ext_ens
#
#    elseif analysis=="etks-adaptive"
#        ## NOTE: STILL DEVELOPMENT VERSION, NOT DEBUGGED
#        # needs to be revised for unweighted anomalies
#        # This computes the transform of the ETKF update as in Asch, Bocquet, Nodet
#        # but using a computation of the contribution of the model error covariance matrix Q
#        # in the square root as in Raanes et al. 2015 and the adaptive inflation from the
#        # frequentist estimator for the model error covariance
#        # step 0: infer the system, observation and ensemble dimensions 
#        sys_dim, N_ens = size(ens)
#        obs_dim = length(obs)
#
#        # step 1: compute the ensemble mean
#        x_mean = mean(ens, dims=2)
#
#        # step 2a: compute the normalized anomalies
#        A = (ens .- x_mean) / sqrt(N_ens - 1.0)
#
#        if !(m_err[1] == Inf)
#            # step 2b: compute the SVD for the two-sided projected model error covariance
#            F_ens = svd(A)
#            mean_err = mean(m_err, dims=2)
#
#            # NOTE: may want to consider separate formulations in which we treat
#            # the model error mean known versus unknown
#            # A_err = (m_err .- mean_err) / sqrt(length(mean_err) - 1.0)
#            A_err = m_err / sqrt(size(m_err, 2))
#            F_err = svd(A_err)
#            if N_ens <= sys_dim
#                Σ_pinv = Diagonal([1.0 ./ F_ens.S[1:N_ens-1]; 0.0]) 
#            else
#                Σ_pinv = Diagonal(1.0 ./ F_ens.S)
#            end
#
#            # step 2c: compute the square root covariance with model error anomaly
#            # contribution in the ensemble space dimension, note the difference in
#            # equation due to the normalized anomalies
#            G = Symmetric(I +  Σ_pinv * transpose(F_ens.U) * F_err.U *
#                          Diagonal(F_err.S.^2) * transpose(F_err.U) * 
#                          F_ens.U * Σ_pinv)
#            
#            G = F_ens.V * square_root(G) * F_ens.Vt
#
#            # step 2c: compute the model error adjusted anomalies
#            A = A * G
#        end
#
#        # step 3: compute the ensemble in observation space
#        Y = alternating_obs_operator(ens, obs_dim, kwargs)
#
#        # step 4: compute the ensemble mean in observation space
#        y_mean = mean(Y, dims=2)
#        
#        # step 5: compute the weighted anomalies in observation space
#        
#        # first we find the observation error covariance inverse
#        obs_sqrt_inv = square_root_inv(obs_cov)
#        
#        # then compute the weighted anomalies
#        S = (Y .- y_mean) / sqrt(N_ens - 1.0)
#        S = obs_sqrt_inv * S
#
#        # step 6: compute the weighted innovation
#        δ = obs_sqrt_inv * ( obs - y_mean )
#       
#        # step 7: compute the transform matrix
#        T = inv(Symmetric(1.0I + transpose(S) * S))
#        
#        # step 8: compute the analysis weights
#        w = T * transpose(S) * δ
#
#        # step 9: compute the square root of the transform
#        T = sqrt(T)
#        
#        # step 10:  generate mean preserving random orthogonal matrix as in sakov oke 08
#        U = rand_orth(N_ens)
#
#        # step 11: package the transform output tuple
#        T, w, U
#
#    elseif analysis=="etkf-hybrid" || analysis=="etks-hybrid"
#        # NOTE: STILL DEVELOPMENT VERSION, NOT DEBUGGED
#        # step 0: infer the system, observation and ensemble dimensions 
#        sys_dim, N_ens = size(ens)
#        obs_dim = length(obs)
#
#        # step 1: compute the background in observation space, and the square root hybrid
#        # covariance
#        Y = H * conditioning
#        x_mean = mean(ens, dims=2)
#        X = (ens .- x_mean)
#        Σ = inv(conditioning) * X
#
#        # step 2: compute the ensemble mean in observation space
#        Y_ens = H * ens
#        y_mean = mean(Y_ens, dims=2)
#        
#        # step 3: compute the sensitivity matrix in observation space
#        obs_sqrt_inv = square_root_inv(obs_cov)
#        Γ = obs_sqrt_inv * Y
#
#        # step 4: compute the weighted innovation
#        δ = obs_sqrt_inv * ( obs - y_mean )
#       
#        # step 5: run the Gauss-Newton optimization of the cost function
#
#        # step 5a: define the gradient of the cost function for the hybridized covariance
#        function ∇J!(w_full::Vector{Float64})
#            # define the factor to be inverted and compute with the SVD
#            w = w_full[1:end-2]
#            α_1 = w_full[end-1]
#            α_2 = w_full[end]
#            K = (N_ens - 1.0) / α_1 * I + transpose(Σ) * Σ 
#            F = svd(K)
#            K_inv = F.U * Diagonal(1.0 ./ F.S) * F.Vt
#            grad_w = transpose(Γ) * (δ - Γ * w) + w / α_2 - K_inv * w / α_2
#            grad_1 = 1 / α_2 * transpose(w) * K_inv * ( (1.0 - N_ens) / α_1^2.0 * I) *
#                     k_inv * w
#            grad_2 =  -transpose(w) * w / α_2^2.0 + transpose(w) * K_inv * w / α_2^2.0
#            [grad_w; grad_1; grad_2]
#        end
#
#        # step 5b: run the Gauss-Newton iteration
#        w = zeros(N_ens)
#        α_1 = 0.5
#        α_2 = 0.5
#        j = 0
#        w_full = [w; α_1; α_2]
#
#        while j < j_max
#            # compute the gradient and hessian approximation
#            grad_w = ∇J(w_full)
#            hess_w = grad_w * transpose(grad_w)
#
#            # perform Newton approximation, simultaneously computing
#            # the update transform T with the SVD based inverse at once
#            T, hessian_inv = square_root_inv(Symmetric(hess_w), inverse=true)
#            Δw = hessian_inv * grad_w
#            w_full -= Δw
#
#            if norm(Δw) < tol
#                break
#            else
#                j+=1
#            end
#        end
#
#        # step 6: store the ensemble weights
#
#        # step 6: generate mean preserving random orthogonal matrix as in sakov oke 08
#        U = rand_orth(N_ens)
#
#        # step 7: package the transform output tuple
#        T, w, U
#
#
#
