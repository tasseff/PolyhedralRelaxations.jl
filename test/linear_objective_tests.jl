@testset "linear objective function tests" begin
    PR.logger_config!("error")
    f, partition = x -> x^3, collect(-1.0:0.05:1.0)

    # create LP relaxation of the MILP relaxation of the univariate function.
    milp_relaxation, milp_function_data = construct_milp_relaxation(f, partition)
    milp = Model(glpk_optimizer)
    lb, ub = get_variable_bounds(milp_relaxation)
    num_variables = get_num_variables(milp_relaxation)
    @variable(milp, lb[i] <= x[i=1:num_variables] <= ub[i])
    A, b = get_eq_constraint_matrices(milp_relaxation)
    @constraint(milp, A * x .== b)
    A, b = get_leq_constraint_matrices(milp_relaxation)
    @constraint(milp, A * x .<= b)

    # create LP relaxation of the univariate function using the convex hull formulation.
    lp_relaxation, lp_function_data = construct_lp_relaxation(f, partition)
    lp = Model(glpk_optimizer)
    lb, ub = get_variable_bounds(lp_relaxation)
    num_variables = get_num_variables(lp_relaxation)
    @variable(lp, lb[i] <= y[i=1:num_variables] <= ub[i])
    A, b = get_eq_constraint_matrices(lp_relaxation)
    @constraint(lp, A * y .== b)

    for i in 1:10
        α = rand() * 2 * pi
        @objective(milp, Min, x[milp_relaxation.y_index] - tan(α) * x[milp_relaxation.x_index])
        @objective(lp, Min, y[lp_relaxation.y_index] - tan(α) * y[lp_relaxation.x_index])
        optimize!(milp)
        optimize!(lp)
        @test objective_value(milp) ≈ objective_value(lp) atol=1e-5

        set_objective_sense(milp, MOI.MAX_SENSE)
        set_objective_sense(lp, MOI.MAX_SENSE)
        optimize!(milp)
        optimize!(lp)
        @test objective_value(milp) ≈ objective_value(lp) atol=1e-5
    end

    # sec_verts, tan_verts = collect_vertices(function_data)
end
