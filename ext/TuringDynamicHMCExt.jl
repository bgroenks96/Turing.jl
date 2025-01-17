module TuringDynamicHMCExt
###
### DynamicHMC backend - https://github.com/tpapp/DynamicHMC.jl
###


if isdefined(Base, :get_extension)
    import DynamicHMC
    using Turing
    using Turing: AbstractMCMC, Random, LogDensityProblems, DynamicPPL
    using Turing.Inference: LogDensityProblemsAD, TYPEDFIELDS
else
    import ..DynamicHMC
    using ..Turing
    using ..Turing: AbstractMCMC, Random, LogDensityProblems, DynamicPPL
    using ..Turing.Inference: LogDensityProblemsAD, TYPEDFIELDS
end

"""
    DynamicNUTS

Dynamic No U-Turn Sampling algorithm provided by the DynamicHMC package.

To use it, make sure you have DynamicHMC package (version >= 2) loaded:
```julia
using DynamicHMC
```
""" 
struct DynamicNUTS{AD,space,T<:DynamicHMC.NUTS} <: Turing.Inference.Hamiltonian{AD} 
    sampler::T
end

DynamicNUTS(args...) = DynamicNUTS{Turing.ADBackend()}(args...)
DynamicNUTS{AD}(spl::DynamicHMC.NUTS, space::Tuple) where AD = DynamicNUTS{AD, space, typeof(spl)}(spl)
DynamicNUTS{AD}(spl::DynamicHMC.NUTS) where AD = DynamicNUTS{AD}(spl, ())
DynamicNUTS{AD}() where AD = DynamicNUTS{AD}(DynamicHMC.NUTS())
Turing.externalsampler(spl::DynamicHMC.NUTS) = DynamicNUTS(spl)

DynamicPPL.getspace(::DynamicNUTS{<:Any, space}) where {space} = space

"""
    DynamicNUTSState

State of the [`DynamicNUTS`](@ref) sampler.

# Fields
$(TYPEDFIELDS)
"""
struct DynamicNUTSState{L,V<:DynamicPPL.AbstractVarInfo,C,M,S}
    logdensity::L
    vi::V
    "Cache of sample, log density, and gradient of log density evaluation."
    cache::C
    metric::M
    stepsize::S
end

DynamicPPL.initialsampler(::DynamicPPL.Sampler{<:DynamicNUTS}) = DynamicPPL.SampleFromUniform()

function DynamicPPL.initialstep(
    rng::Random.AbstractRNG,
    model::DynamicPPL.Model,
    spl::DynamicPPL.Sampler{<:DynamicNUTS},
    vi::DynamicPPL.AbstractVarInfo;
    kwargs...
)
    # Ensure that initial sample is in unconstrained space.
    if !DynamicPPL.islinked(vi, spl)
        vi = DynamicPPL.link!!(vi, spl, model)
        vi = last(DynamicPPL.evaluate!!(model, vi, DynamicPPL.SamplingContext(rng, spl)))
    end

    # Define log-density function.
    ℓ = LogDensityProblemsAD.ADgradient(Turing.LogDensityFunction(vi, model, spl, DynamicPPL.DefaultContext()))

    # Perform initial step.
    results = DynamicHMC.mcmc_keep_warmup(
        rng,
        ℓ,
        0;
        initialization = (q = vi[spl],),
        reporter = DynamicHMC.NoProgressReport(),
    )
    steps = DynamicHMC.mcmc_steps(results.sampling_logdensity, results.final_warmup_state)
    Q, _ = DynamicHMC.mcmc_next_step(steps, results.final_warmup_state.Q)

    # Update the variables.
    vi = DynamicPPL.setindex!!(vi, Q.q, spl)
    vi = DynamicPPL.setlogp!!(vi, Q.ℓq)

    # Create first sample and state.
    sample = Turing.Inference.Transition(vi)
    state = DynamicNUTSState(ℓ, vi, Q, steps.H.κ, steps.ϵ)

    return sample, state
end

function AbstractMCMC.step(
    rng::Random.AbstractRNG,
    model::DynamicPPL.Model,
    spl::DynamicPPL.Sampler{<:DynamicNUTS},
    state::DynamicNUTSState;
    kwargs...
)
    # Compute next sample.
    vi = state.vi
    ℓ = state.logdensity
    steps = DynamicHMC.mcmc_steps(
        rng,
        spl.alg.sampler,
        state.metric,
        ℓ,
        state.stepsize,
    )
    Q, _ = DynamicHMC.mcmc_next_step(steps, state.cache)

    # Update the variables.
    vi = DynamicPPL.setindex!!(vi, Q.q, spl)
    vi = DynamicPPL.setlogp!!(vi, Q.ℓq)

    # Create next sample and state.
    sample = Turing.Inference.Transition(vi)
    newstate = DynamicNUTSState(ℓ, vi, Q, state.metric, state.stepsize)

    return sample, newstate
end

end