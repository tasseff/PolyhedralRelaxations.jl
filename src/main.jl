using Memento
using SparseArrays

# logger_config!("debug")

"""
    collect_secant_vertices(f, partition_points)

Return a list of (x,y) coordinates of secant vertices as Pair objects.

The x value of each coordinate is an element of `partition_points`.
The y value of each coordinate is the evaluation of the given univariate
function `f` at x, i.e. y = f(x).

In terms of notation in the paper, the returned vertices are v_i values.
"""
function collect_secant_vertices(
        f::Function,
        partition_points::Vector{Real})::Vector{Vertex}
    secant_vertices = Vertex[]
    num_points = length(partition_points)
    for x in partition_points
        push!(secant_vertices, Pair(x, f(x)))
        v = secant_vertices[end]
        info(_LOGGER, "x: $x v_x: $(v[1]) v_y: $(v[2]) ")
    end
    return secant_vertices
end

"""
    collect_tangent_vertices(f_dash, secant_vertices)

Return a list of (x,y) coordinates of tangent intersections as Pair objects.

Each position i of the returned list contains the (x,y) coordinate of the
vertex formed by intersection of tangents of the required curve y = f(x) at
`secant_vertices[i]` and `secant_vertices[i+1]`. The function `f_dash` is the
derivative of f(x).

In terms of notation in the paper, `secant_vertices[i]` is the vertex v_i,
`secant_vertices[i+1]` is the vertex v_{i+1} and `tangent_vertices[i]` is
the vertex v_{i,i+1}.
"""
function collect_tangent_vertices(
        f_dash::Function,
        secant_vertices::Vector{Vertex})::Vector{Vertex}
    num_points = length(secant_vertices)
    tangent_vertices = Vertex[]

    for i in 1:num_points-1
        v1 = secant_vertices[i]
        v2 = secant_vertices[i+1]

        # Find derivative values at secant points. Validate that successive
        # partition points cannot have the same derivative, as if so, the
        # tangents at these points will be parallel and won't form a triangle.
        d1 = f_dash(v1[1])
        d2 = f_dash(v2[1])
        @assert !isapprox(d1, d2, atol=1e-5)

        # Compute x-coordinate of the tangent vertex. This is the intersection
        # of tangents to the curve at v1[1] and v2[1].
        x_new = (v2[2] - v1[2] + (d1*v1[1]) - (d2*v2[1])) / (d1 - d2)
        @assert x_new >= v1[1]
        @assert x_new <= v2[1]

        y_new = v1[2] + (d1*(x_new - v1[1]))
        push!(tangent_vertices, Pair(x_new, y_new))
        info(_LOGGER,  "x0: $(v1[1]) x1: $(v2[1]) x_new: $x_new y_new: $y_new")
    end
    return tangent_vertices
end

"""
    build_model(uf, secant_vertices, tangent_vertices)

Collect constraint data of the MILP formulation of the polyhedral relaxation
in a Model object and return it.
"""
function build_model(
        uf::UnivariateFunction,
        secant_vertices::Vector{Vertex},
        tangent_vertices::Vector{Vertex})::Model
    info(_LOGGER, "starting to build model...")

    # Indices to recover variable values from model. Indices of delta_1^i,
    # delta_2^i and z_i start from 1.
    num_points = length(secant_vertices)
    index_data = IndexData(num_points)
    info(_LOGGER, "number of partition points: $num_points")

    i_start = index_data.delta_1_indices[1]
    i_end = index_data.delta_1_indices[end]
    info(_LOGGER, "delta_1_indices: $i_start to $i_end")

    i_start = index_data.delta_2_indices[1]
    i_end = index_data.delta_2_indices[end]
    info(_LOGGER, "delta_2_indices: $i_start to $i_end")

    i_start = index_data.z_indices[1]
    i_end = index_data.z_indices[end]
    info(_LOGGER, "z_indices: $i_start to $i_end")

    constraint_data = ConstraintData()
    add_vertex_constraints(constraint_data, index_data, secant_vertices, tangent_vertices)
    add_first_delta_constraint(constraint_data, index_data)
    add_linking_constraints(constraint_data, index_data, num_points-1)

    # Ensure that constraint symbols are valid.
    for s in constraint_data.constraint_senses
        @assert s in possible_senses
    end

    # Store constraint data into a Model object and return it.
    A = sparse(constraint_data.constraint_row_indices,
        constraint_data.constraint_column_indices,
        constraint_data.constraint_coefficients)
    b = sparsevec(constraint_data.rhs_row_indices, constraint_data.rhs_values)
    info(_LOGGER, "completed building model.")

    return Model(A, b,
        index_data.x_index,
        index_data.y_index,
        index_data.delta_1_indices,
        index_data.delta_2_indices,
        index_data.z_indices,
        constraint_data.constraint_senses)
end

"""
    add_vertex_constraints(constraint_data, index_data, secant_vertices,
        tangent_vertices)

Add vertex constraints to `constraint_data` using variable indices from
`index_data`.

These constraints link the x and y coordinate variables to the delta variables.
The lists `secant_vertices` and `tangent_vertices` are used to compute
coefficients of delta variables.
"""
function add_vertex_constraints(
        constraint_data::ConstraintData,
        index_data::IndexData,
        secant_vertices::Vector{Vertex},
        tangent_vertices::Vector{Vertex})
    indices = [index_data.x_index, index_data.y_index]
    num_vars = length(secant_vertices) - 1

    for c in [1,2]  # c is the coordinate index (1 for x, 2 for y).
        row = constraint_data.num_constraints+1

        # Add coordinate variable to constraint.
        add_coef(constraint_data, row, indices[c], 1)

        for i in 1:num_vars
            # Add delta_1 variable to constraint.
            column = index_data.delta_1_indices[i]
            value = secant_vertices[i][c] - tangent_vertices[i][c]
            add_coef(constraint_data, row, column, value)

            # Add delta_2 variable to constraint.
            column = index_data.delta_2_indices[i]
            value = secant_vertices[i][c] - secant_vertices[i+1][c]
            add_coef(constraint_data, row, column, value)
        end

        # Complete the constraint.
        push!(constraint_data.constraint_senses, :eq)
        add_rhs(constraint_data, row, secant_vertices[1][c])
        constraint_data.num_constraints += 1
    end

    info(_LOGGER, "built vertex constraints.")
end

"""
    add_first_delta_constraint(constraint_data, index_data)

Add the constraint "delta_1^1 + delta_2^1 <= 1 to `constraint_data` using
variable indices from `index_data`.
"""
function add_first_delta_constraint(
        constraint_data::ConstraintData,
        index_data::IndexData)
    row = constraint_data.num_constraints + 1
    add_coef(constraint_data, row, index_data.delta_1_indices[1], 1)
    add_coef(constraint_data, row, index_data.delta_2_indices[1], 1)
    push!(constraint_data.constraint_senses, :leq)
    add_rhs(constraint_data, row, 1)
    constraint_data.num_constraints += 1
    info(_LOGGER, "built delta_1^1 + delta_2^1 <= 1 constraint.")
end

"""
    add_linking_constraint(constraint_data, index_data, num_vars)

Add the constraint families

    delta_1^i + delta_2^i - z_{i-1} <= 0
    delta_2^{i-1} >= z_{i-1}

to `constraint_data` using variable indices from `index_data`. The number of
each of these constraints corresponds to the number of triangles specified by
`num_triangles`.
"""
function add_linking_constraints(
        constraint_data::ConstraintData,
        index_data::IndexData,
        num_triangles::Int64)
    for i in 2:num_triangles
        constraint_data.num_constraints += 1
        row = constraint_data.num_constraints

        # Add delta_1^i + delta_2^i - z_{i-1} <= 0 constraint.
        add_coef(constraint_data, row, index_data.delta_1_indices[i], 1)
        add_coef(constraint_data, row, index_data.delta_2_indices[i], 1)
        add_coef(constraint_data, row, index_data.z_indices[i-1], -1)
        push!(constraint_data.constraint_senses, :leq)
        add_rhs(constraint_data, row, 0)

        # Add delta_2^{i-1} - z_{i-1} >+ 0 constraint.
        constraint_data.num_constraints += 1
        row = constraint_data.num_constraints
        add_coef(constraint_data, row, index_data.delta_2_indices[i-1], 1)
        add_coef(constraint_data, row, index_data.z_indices[i-1], -1)
        push!(constraint_data.constraint_senses, :geq)
        add_rhs(constraint_data, row, 0)
    end
    info(_LOGGER, "added linking constraints.")
end

"""
    add_coef(constraint_data, row, col, value)

Add the coefficient `value` of the variable with index `col` to the constraint
with index `row` to `constraint_data`.
"""
function add_coef(
        constraint_data::ConstraintData,
        row::Int64,
        col::Int64,
        value::Real)
    push!(constraint_data.constraint_row_indices, row)
    push!(constraint_data.constraint_column_indices, col)
    push!(constraint_data.constraint_coefficients, value)
end

"""
    add_rhs(constraint_data, row, value)

Add the right-hand-side `value` for row `row` to `constraint_data`.
"""
function add_rhs(
        constraint_data::ConstraintData,
        row::Int64,
        value::Real)
    push!(constraint_data.rhs_row_indices, row)
    push!(constraint_data.rhs_values, value)
end

"""
    main()

Generate model data for the polyhedral relaxation of a univariate function.
"""
function main()
    info(_LOGGER, "starting model generation...")

    lb = -2.0
    ub = 2.0
    uf = UnivariateFunction(
        x->x^3,  # f
        x->3 * (x^2),  # f'
        domain_lb = lb,
        domain_ub = ub,
        inflection_points = Vector{Real}(collect(lb:0.25:ub)))

    sec_vertices = collect_secant_vertices(uf.f, uf.inflection_points)
    info(_LOGGER, "collected $(length(sec_vertices)) secant vertices.")

    tan_vertices = collect_tangent_vertices(uf.f_dash, sec_vertices)
    info(_LOGGER, "collected $(length(tan_vertices)) tangent vertices.")

    model = build_model(uf, sec_vertices, tan_vertices)
    info(_LOGGER, "completed model generation.")
end