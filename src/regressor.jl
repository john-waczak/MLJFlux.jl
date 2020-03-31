mutable struct NeuralNetworkRegressor{B<:Builder,O,L} <: MLJModelInterface.Deterministic
    builder::B
    optimiser::O    # mutable struct from Flux/src/optimise/optimisers.jl
    loss::L         # can be called as in `loss(yhat, y)`
    epochs::Int     # number of epochs
    batch_size::Int # size of a batch
    lambda::Float64 # regularization strength
    alpha::Float64  # regularizaton mix (0 for all l2, 1 for all l1)
    optimiser_changes_trigger_retraining::Bool
end

NeuralNetworkRegressor(; builder::B   = Linear()
              , optimiser::O = Flux.Optimise.ADAM()
              , loss::L      = Flux.mse
              , epochs       = 10
              , batch_size   = 1
              , lambda       = 0
              , alpha        = 0
              , optimiser_changes_trigger_retraining=false
              ) where {B,O,L} =
                  NeuralNetworkRegressor{B,O,L}(builder
                                       , optimiser
                                       , loss
                                       , epochs
                                       , batch_size
                                       , lambda
                                       , alpha
                                       , optimiser_changes_trigger_retraining)


mutable struct MultitargetNeuralNetworkRegressor{B<:Builder,O,L} <: MLJModelInterface.Deterministic
    builder::B
    optimiser::O    # mutable struct from Flux/src/optimise/optimisers.jl
    loss::L         # can be called as in `loss(yhat, y)`
    epochs::Int          # number of epochs
    batch_size::Int # size of a batch
    lambda::Float64 # regularization strength
    alpha::Float64  # regularizaton mix (0 for all l2, 1 for all l1)
    optimiser_changes_trigger_retraining::Bool
end

MultitargetNeuralNetworkRegressor(; builder::B   = Linear()
              , optimiser::O = Flux.Optimise.ADAM()
              , loss::L      = Flux.mse
              , epochs       = 10
              , batch_size   = 1
              , lambda       = 0
              , alpha        = 0
              , optimiser_changes_trigger_retraining=false
              ) where {B,O,L} =
                  MultitargetNeuralNetworkRegressor{B,O,L}(builder
                                       , optimiser
                                       , loss
                                       , epochs
                                       , batch_size
                                       , lambda
                                       , alpha
                                       , optimiser_changes_trigger_retraining)

const Regressor =
    Union{NeuralNetworkRegressor, MultitargetNeuralNetworkRegressor}

function nrows(X)
    Tables.istable(X) || throw(ArgumentError)
    Tables.columnaccess(X) || return length(collect(X))
    # if has columnaccess
    cols = Tables.columntable(X)
    !isempty(cols) || return 0
    return length(cols[1])
end
nrows(y::AbstractVector) = length(y)

function collate(model::Regressor, X, y, batch_size)

    row_batches = Base.Iterators.partition(1:nrows(y), batch_size)

    Xmatrix = MLJModelInterface.matrix(X)'
    if Tables.istable(y)
        ymatrix = MLJModelInterface.matrix(y)'
        return [(Xmatrix[:, b], ymatrix[:, b]) for b in row_batches]
    else
        ymatrix = reduce(hcat, [[tup...] for tup in y])
        return [((Xmatrix[:, b]), ymatrix[b]) for b in row_batches]
    end
end

function MLJModelInterface.fit(model::Regressor, verbosity::Int, X, y)

    # When it has no categorical features
    n_input = Tables.schema(X).names |> length
    data = collate(model, X, y, model.batch_size)

    target_is_multivariate = Tables.istable(y)
    if target_is_multivariate
        target_column_names = Tables.schema(y).names
    else
        target_column_names = [""] # We won't be using this
    end

    n_output = length(target_column_names)
    chain = fit(model.builder, n_input, n_output)

    optimiser = deepcopy(model.optimiser)

    chain, history = fit!(chain, optimiser, model.loss,
                          model.epochs, model.batch_size,
                          model.lambda, model.alpha,
                          verbosity, data)

    cache = (deepcopy(model), data, history, n_input, n_output)
    fitresult = (chain, target_is_multivariate, target_column_names)
    report = (training_losses=history,)

    return fitresult, cache, report

end

function MLJModelInterface.predict(model::Regressor, fitresult, Xnew_)

    chain , target_is_multivariate, target_column_names = fitresult

    Xnew_ = MLJModelInterface.matrix(Xnew_)

    if target_is_multivariate
        ypred = [map(x->x.data, chain(values.(Xnew_[i, :])))
                 for i in 1:size(Xnew_, 1)]
        return MLJModelInterface.table(reduce(hcat, y for y in ypred)',
                                       names=target_column_names)
    else
        return [chain(values.(Xnew_[i, :]))[1] for i in 1:size(Xnew_, 1)]
    end
end

function MLJModelInterface.update(model::Regressor,
                                  verbosity::Int,
                                  old_fitresult,
                                  old_cache,
                                  X,
                                  y)

    old_model, data, old_history, n_input, n_output = old_cache
    old_chain, target_is_multivariate, target_column_names = old_fitresult

    optimiser_flag = model.optimiser_changes_trigger_retraining &&
        model.optimiser != old_model.optimiser

    keep_chain = !optimiser_flag && model.epochs >= old_model.epochs &&
        MLJModelInterface.is_same_except(model, old_model, :optimizer, :epochs)

    if keep_chain
        chain = old_chain
        epochs = model.epochs - old_model.epochs
    else
        chain = fit(model.builder, n_input, n_output)
        data = collate(model, X, y, model.batch_size)
        epochs = model.epochs
    end

    optimiser = deepcopy(model.optimiser)

    chain, history = fit!(chain, optimiser, model.loss, epochs,
                                model.batch_size, model.lambda, model.alpha,
                                verbosity, data)
    if keep_chain
        history = vcat(old_history, history)
    end
    fitresult = (chain, target_is_multivariate, target_column_names)
    cache = (deepcopy(model), data, history, n_input, n_output)
    report = (training_losses=history,)

    return fitresult, cache, report

end

MLJModelInterface.metadata_model(NeuralNetworkRegressor,
               input=MLJModelInterface.Table(MLJModelInterface.Continuous),
               target=AbstractVector{<:MLJModelInterface.Continuous},
               path="MLJFlux.NeuralNetworkRegressor",
               descr = "A neural network model for making deterministic predictions of a
               `Continuous` multi-target, presented as a table,  given a table of `Continuous` features. ")


MLJModelInterface.metadata_model(MultitargetNeuralNetworkRegressor,
               input=MLJModelInterface.Table(MLJModelInterface.Continuous),
               target=MLJModelInterface.Table(MLJModelInterface.Continuous),
               path="MLJFlux.NeuralNetworkRegressor",
               descr = "A neural network model for making deterministic predictions of a
                    `Continuous` mutli-target, presented as a table,  given a table of `Continuous` features.")
