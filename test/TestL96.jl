##############################################################################################
module TestL96
##############################################################################################
##############################################################################################
# imports and exports
using DataAssimilationBenchmarks.DeSolvers, DataAssimilationBenchmarks.L96

##############################################################################################
##############################################################################################
# Test the derivative function for known behavior with Euler method,
# the initial condiiton of zeros give back h * F in all components

function EMZerosStep()
    # step size
    h = 0.01
    
    # forcing parameter
    F = 8.0
    dx_params = Dict{String, Array{Float64}}("F" => [F])

    # initial conditions and arguments
    x = zeros(40)

    # parameters to test
    kwargs = Dict{String, Any}(
        "h" => h,
        "diffusion" => 0.0,
        "dx_params" => dx_params,
        "dx_dt" => L96.dx_dt,
        )

    # em_step! writes over x in place
    em_step!(x, 0.0, kwargs)

    # evaluate test pass/fail if the vector of x is equal to (f*h) in every instance
    if sum(x .== (F*h)) == 40
        true
    else
        false
    end

end


##############################################################################################
# Test the derivative function for known behavior with Euler method,
# the vector with all components equal to F is a fixed point for the system

function EMFStep()
    # step size
    h = 0.01
    
    # forcing parameter
    F = 8.0
    dx_params = Dict{String, Array{Float64}}("F" => [F])

    # initial conditions and arguments
    x = ones(40)
    x = x * F

    # parameters to test
    kwargs = Dict{String, Any}(
        "h" => h,
        "diffusion" => 0.0,
        "dx_params" => dx_params,
        "dx_dt" => L96.dx_dt,
        )

    # em_step! writes over x in place
    em_step!(x, 0.0, kwargs)

    # evaluate test pass/fail if the vector of x is equal to (f*h) in every instance
    if sum(x .== (F)) == 40
        true
    else
        false
    end

end


##############################################################################################
# end module

end
