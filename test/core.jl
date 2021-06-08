Random.seed!(123)

@test MLJFlux.MLJModelInterface.istransparent(Flux.ADAM(0.1))

@testset "nrows" begin
    Xmatrix = rand(10, 3)
    X = MLJBase.table(Xmatrix)
    @test MLJFlux.nrows(X) == 10
    @test MLJFlux.nrows(Tables.columntable(X)) == 10
end

@testset "collate" begin
    # NeuralNetworRegressor:
    Xmatrix = broadcast(x->round(x, sigdigits=2), rand(10, 3))
    # convert to a column table:
    X = MLJBase.table(Xmatrix)

    y = rand(10)
    model = MLJFlux.NeuralNetworkRegressor()
    model.batch_size= 3
    @test MLJFlux.collate(model, X, y) ==
        ([Xmatrix'[:,1:3], Xmatrix'[:,4:6], Xmatrix'[:,7:9], Xmatrix'[:,10:10]], [y[1:3], y[4:6], y[7:9], y[10:10]])

    # NeuralNetworClassifier:
    y = categorical(['a', 'b', 'a', 'a', 'b', 'a', 'a', 'a', 'b', 'a'])
    model = MLJFlux.NeuralNetworkClassifier()
    model.batch_size = 3
    data = MLJFlux.collate(model, X, y)

    @test data == ([Xmatrix'[:,1:3], Xmatrix'[:,4:6], Xmatrix'[:,7:9], Xmatrix'[:,10:10]],
        [[1 0 1; 0 1 0], [1 0 1; 0 1 0], [1 1 0; 0 0 1], reshape([1; 0], (2,1))])

    # MultitargetNeuralNetworRegressor:
    ymatrix = rand(10, 2)
    y = MLJBase.table(ymatrix) # a rowaccess table
    model = MLJFlux.NeuralNetworkRegressor()
    model.batch_size= 3
    @test MLJFlux.collate(model, X, y) ==
        ([Xmatrix'[:,1:3], Xmatrix'[:,4:6], Xmatrix'[:,7:9], Xmatrix'[:,10:10]],
                [ymatrix'[:,1:3], ymatrix'[:,4:6], ymatrix'[:,7:9], ymatrix'[:,10:10]])

    y = Tables.columntable(y) # try a columnaccess table
    @test MLJFlux.collate(model, X, y) ==
        ([Xmatrix'[:,1:3], Xmatrix'[:,4:6], Xmatrix'[:,7:9], Xmatrix'[:,10:10]],
            [ymatrix'[:,1:3], ymatrix'[:,4:6], ymatrix'[:,7:9], ymatrix'[:,10:10]])

    # ImageClassifier
    Xmatrix = coerce(rand(6, 6, 1, 10), GrayImage)
    y = categorical(['a', 'b', 'a', 'a', 'b', 'a', 'a', 'a', 'b', 'a'])
    model = MLJFlux.ImageClassifier(batch_size=2)

    data = MLJFlux.collate(model, Xmatrix, y)
    @test  first.(data) == (Float32.(cat(Xmatrix[1], Xmatrix[2], dims=4)), [1 0;0 1])

    expected_y = [[1 0;0 1], [1 1;0 0], [0 1; 1 0], [1 1;0 0], [0 1; 1 0]]
    for i=1:5
        @test Int.(last(data)[i]) == expected_y[i]
    end

end

Xmatrix = rand(100, 5)
X = MLJBase.table(Xmatrix)
y = Xmatrix[:, 1] + Xmatrix[:, 2] + Xmatrix[:, 3] +
    Xmatrix[:, 4] + Xmatrix[:, 5]

data = [(Xmatrix'[:,1:20], y[1:20]),
        (Xmatrix'[:,21:40], y[21:40]),
        (Xmatrix'[:,41:60], y[41:60]),
        (Xmatrix'[:,61:80], y[61:80]),
        (Xmatrix'[:, 81:100], y[81:100])]

data = ([Xmatrix'[:,1:20], Xmatrix'[:,21:40], Xmatrix'[:,41:60], Xmatrix'[:,61:80], Xmatrix'[:,81:100]],
            [y[1:20], y[21:40], y[41:60], y[61:80], y[81:100]])

# construct two chains with identical state, except one has
# dropout and the other does not:
chain_yes_drop = Flux.Chain(Flux.Dense(5, 15),
                            Flux.Dropout(0.2),
                            Flux.Dense(15, 8),
                            Flux.Dense(8, 1))

chain_no_drop = deepcopy(chain_yes_drop)
chain_no_drop.layers[2].p = 1.0

test_input = rand(Float32, 5, 1)

# check both chains have same behaviour before training:
@test chain_yes_drop(test_input) == chain_no_drop(test_input)

epochs = 10

@testset_accelerated "fit! and dropout" accel begin

    move = MLJFlux.Mover(accel)

    Random.seed!(123)

    _chain_yes_drop, history = MLJFlux.fit!(chain_yes_drop,
                                            Flux.Optimise.ADAM(0.001),
                                            Flux.mse, epochs, 0, 0, 0, accel, data[1], data[2])

    println()

    Random.seed!(123)

    _chain_no_drop, history = MLJFlux.fit!(chain_no_drop,
                                           Flux.Optimise.ADAM(0.001),
                                           Flux.mse, epochs, 0, 0, 0, accel, data[1], data[2])

    # check chains have different behaviour after training:
    @test !(_chain_yes_drop(test_input) ≈ _chain_no_drop(test_input))

    # check chain with dropout is deterministic outside of training
    # (if we do not differentiate):
    @test all(_chain_yes_drop(test_input) ==
              _chain_yes_drop(test_input) for i in 1:1000)

    @test length(history) == epochs + 1

end


# to control chain initialization:
myinit(n, m) = reshape(float(1:n*m), n , m)

mutable struct TESTBuilder <: MLJFlux.Builder end
MLJFlux.build(builder::TESTBuilder, n_in, n_out) =
    Chain(Flux.Dense(n_in, n_out, init=myinit))

@testset_accelerated "issue #152" accel begin

    # data:
    n = 100
    d = 5
    Xmat = rand(Float64, n, d)
    X = MLJBase.table(Xmat);
    y = X.x1 .^2 + X.x2 .* X.x3 - 4 * X.x4

    # train a model on all the data using batch size > 1:
    model = MLJFlux.NeuralNetworkRegressor(builder = TESTBuilder(),
                                   batch_size=25,
                                   epochs=1,
                                   loss=Flux.mse)
    mach = machine(model, X, y)
    fit!(mach, verbosity=0)

    # extract the pre-training loss computed in the `fit!(chain, ...)` method:
    pretraining_loss = report(mach).training_losses[1]

    # compute by hand:
    chain0 = myinit(1, d)
    pretraining_yhat = Xmat*chain0' |> vec
    @test y isa Vector && pretraining_yhat isa Vector
    pretraining_loss_by_hand =  MLJBase.l2(pretraining_yhat, y) |> mean

    # compare:
    @test_broken pretraining_loss ≈ pretraining_loss_by_hand

end
