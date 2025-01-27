##############################################################################################
module runtests
##############################################################################################
##############################################################################################
# imports and exports
using Test
using JLD2

##############################################################################################
##############################################################################################
# include test sub-modules
include("TestDeSolvers.jl")
include("TestL96.jl")
include("TestTimeSeriesGeneration.jl")
include("TestIEEE39bus.jl")
include("TestFilterExps.jl")

##############################################################################################
##############################################################################################
# Run tests

# test set 1: Calculate the order of convergence for standard integrators
@testset "Calculate Order Convergence" begin
    @test TestDeSolvers.testEMExponential()
    @test TestDeSolvers.testRKExponential()
end

# test set 2: test L96 model equations for known behavior
@testset "Lorenz-96" begin
    @test TestL96.EMZerosStep()
    @test TestL96.EMFStep()
end

# test set 3: Test time series generation, saving output to default directory and loading
@testset "Time Series Generation" begin
    @test TestTimeSeriesGeneration.testGenL96()
    @test TestTimeSeriesGeneration.testLoadL96()
    @test TestTimeSeriesGeneration.testGenIEEE39bus()
    @test TestTimeSeriesGeneration.testLoadIEEE39bus()
end

# test set 4: test the model equations for known behavior
@testset "IEEE 39 Bus" begin
    @test TestIEEE39bus.test_synchrony()
end

# test set 5: test filter state and parameter experiments
@testset "Filter Experiments" begin
    @test TestFilterExps.run_filter_state_L96()
    @test TestFilterExps.analyze_filter_state_L96()
    @test TestFilterExps.run_filter_param_L96()
    @test TestFilterExps.analyze_filter_param_L96()
    @test TestFilterExps.run_filter_state_IEEE39bus()
    @test TestFilterExps.analyze_filter_state_IEEE39bus()
end


##############################################################################################
# end module

end
