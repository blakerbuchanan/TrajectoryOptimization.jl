"Augmented Lagrangian solve"
function solve!(prob::Problem{T}, solver::AugmentedLagrangianSolver{T}) where T
    reset!(solver)

    solver_uncon = AbstractSolver(prob, solver.opts.opts_uncon)

    prob_al = AugmentedLagrangianProblem(prob, solver)
    logger = default_logger(solver)

    with_logger(logger) do
        for i = 1:solver.opts.iterations
            set_tolerances!(solver,solver_uncon,i)
            J = step!(prob_al, solver, solver_uncon)

            record_iteration!(prob, solver, J, solver_uncon)
            println(logger,OuterLoop)
            evaluate_convergence(solver) ? break : nothing
        end
    end
end

function solve!(prob::Problem{T},opts::AugmentedLagrangianSolverOptions{T}) where T
    !is_constrained(prob) ? solver = AbstractSolver(prob,opts.opts_uncon) : solver = AbstractSolver(prob,opts)
    solve!(prob,solver)
end

"Set intermediate convergence tolerances for unconstrained solve"
function set_tolerances!(solver::AugmentedLagrangianSolver{T},
        solver_uncon::AbstractSolver{T},i::Int) where T
    if i != solver.opts.iterations
        solver_uncon.opts.cost_tolerance = solver.opts.cost_tolerance_intermediate
        solver_uncon.opts.gradient_norm_tolerance = solver.opts.gradient_norm_tolerance_intermediate
    else
        solver_uncon.opts.cost_tolerance = solver.opts.cost_tolerance
        solver_uncon.opts.gradient_norm_tolerance = solver.opts.gradient_norm_tolerance
    end

    return nothing
end

"Augmented Lagrangian step"
function step!(prob::Problem{T}, solver::AugmentedLagrangianSolver{T},
        unconstrained_solver::AbstractSolver) where T

    # Solve the unconstrained problem
    J = solve!(prob, unconstrained_solver)

    reset!(unconstrained_solver)

    # Outer loop update
    dual_update!(prob, solver)
    penalty_update!(prob, solver)
    copyto!(solver.C_prev,solver.C)

    return J
end

"Evaluate maximum constraint violation as metric for Augmented Lagrangian solve convergence"
function evaluate_convergence(solver::AugmentedLagrangianSolver{T}) where T
    solver.stats[:c_max][end] < solver.opts.constraint_tolerance ? true : false
end

function record_iteration!(prob::Problem{T}, solver::AugmentedLagrangianSolver{T}, J::T,
        unconstrained_solver::AbstractSolver) where T
    c_max = max_violation(solver)

    solver.stats[:iterations] += 1
    solver.stats[:iterations_total] += unconstrained_solver.stats[:iterations]
    push!(solver.stats[:iterations_inner], unconstrained_solver.stats[:iterations])
    push!(solver.stats[:cost],J)
    push!(solver.stats[:c_max],c_max)
    push!(solver.stats_uncon, unconstrained_solver.stats)

    @logmsg OuterLoop :iter value=solver.stats[:iterations]
    @logmsg OuterLoop :total value=solver.stats[:iterations_total]
    @logmsg OuterLoop :cost value=J
    @logmsg OuterLoop :c_max value=c_max
end

"Saturate a vector element-wise with upper and lower bounds"
saturate(input::AbstractVector{T}, max_value::T, min_value::T) where T = max.(min_value, min.(max_value, input))

"Dual update (first-order)"
function dual_update!(prob::Problem{T}, solver::AugmentedLagrangianSolver{T}) where T
    c = solver.C; λ = solver.λ; μ = solver.μ

    for k = 1:prob.N
        copyto!(λ[k],saturate(λ[k] + μ[k].*c[k], solver.opts.dual_max,
            solver.opts.dual_min))
        copyto!(λ[k].inequality,max.(0.0, λ[k].inequality))
    end

    # Update active set after updating multipliers (need to calculate c_max)
    update_active_set!(solver.active_set, solver.C, solver.λ)
end

"Penalty update (default) - update all penalty parameters"
function penalty_update!(prob::Problem{T}, solver::AugmentedLagrangianSolver{T}) where T
    μ = solver.μ
    for k = 1:prob.N
        copyto!(μ[k], saturate(solver.opts.penalty_scaling * μ[k], solver.opts.penalty_max, 0.0))
    end
end

"$(TYPEDEF) Augmented Lagrangian Objective: stores stage cost(s) and terminal cost functions"
struct AugmentedLagrangianObjective{T} <: AbstractObjective where T
    cost::CostTrajectory
    constraints::ProblemConstraints
    C::PartedVecTrajectory{T}  # Constraint values
    ∇C::PartedMatTrajectory{T} # Constraint jacobians
    λ::PartedVecTrajectory{T}  # Lagrange multipliers
    μ::PartedVecTrajectory{T}  # Penalty Term
    active_set::PartedVecTrajectory{Bool}  # Active set
end

function AugmentedLagrangianObjective(cost::CostTrajectory,constraints::ProblemConstraints,N::Int;
        μ_init::T=1.,λ_init::T=0.) where T
    # Get sizes
    n,m = get_sizes(cost)
    C,∇C,λ,μ,active_set = init_constraint_trajectories(constraints,n,m,N)
    AugmentedLagrangianObjective{T}(cost,constraint,C,∇C,λ,μ,active_set)
end

function AugmentedLagrangianObjective(cost::CostTrajectory,constraints::ProblemConstraints,
        λ::PartedVecTrajectory{T}; μ_init::T=1.) where T
    # Get sizes
    n,m = get_sizes(cost)
    N = length(λ)
    C,∇C,_,μ,active_set = init_constraint_trajectories(constraints,n,m,N)
    AugmentedLagrangianObjective{T}(cost,constraint,C,∇C,λ,μ,active_set)
end

getindex(obj::AugmentedLagrangianObjective,i::Int) = obj.cost[i]

"Generate augmented Lagrangian cost from unconstrained cost"
function AugmentedLagrangianObjective(prob::Problem{T},
        solver::AugmentedLagrangianSolver{T}) where T
    AugmentedLagrangianObjective{T}(prob.obj.cost,prob.constraints,solver.C,solver.∇C,solver.λ,solver.μ,solver.active_set)
end

"Generate augmented Lagrangian problem from constrained problem"
function AugmentedLagrangianProblem(prob::Problem{T},solver::AugmentedLagrangianSolver{T}) where T
    obj_al = AugmentedLagrangianObjective(prob,solver)
    prob_al = update_problem(prob,obj=obj_al,constraints=ProblemConstraints(),newProb=false)
end

"Evaluate maximum constraint violation"
function max_violation(solver::AugmentedLagrangianSolver{T}) where T
    c_max = 0.0
    C = solver.C
    N = length(C)
    if length(C[1]) > 0
        for k = 1:N-1
            c_max = max(norm(C[k].equality,Inf), c_max)
            if length(C[k].inequality) > 0
                c_max = max(pos(maximum(C[k].inequality)), c_max)
            end
        end
    end
    if length(solver.C[N]) > 0
        c_max = max(norm(C[N].equality,Inf), c_max)
        if length(C[N].inequality) > 0
            c_max = max(pos(maximum(C[N].inequality)), c_max)
        end
    end
    return c_max
end

function cost_expansion!(Q::ExpansionTrajectory{T},obj::AugmentedLagrangianObjective{T},
        X::VectorTrajectory{T},U::VectorTrajectory{T}) where T
    N = length(X)

    cost_expansion!(Q, obj.cost, X, U)

    for k = 1:N-1
        c = obj.C[k]
        λ = obj.λ[k]
        μ = obj.μ[k]
        a = active_set(c,λ)
        Iμ = Diagonal(a .* μ)
        jacobian!(obj.∇C[k],obj.constraints[k],X[k],U[k])
        cx = obj.∇C[k].x
        cu = obj.∇C[k].u

        # Second Order pieces
        Q[k].xx .+= cx'Iμ*cx
        Q[k].uu .+= cu'Iμ*cu
        Q[k].ux .+= cu'Iμ*cx

        # First order pieces
        g = (Iμ*c + λ)
        Q[k].x .+= cx'g
        Q[k].u .+= cu'g
    end

    c = obj.C[N]
    λ = obj.λ[N]
    μ = obj.μ[N]
    a = active_set(c,λ)
    Iμ = Diagonal(a .* μ)
    cx = obj.∇C[N]

    jacobian!(cx,obj.constraints[N],X[N])

    # Second Order pieces
    Q[N].xx .+= cx'Iμ*cx

    # First order pieces
    Q[N].x .+= cx'*(Iμ*c + λ)

    return nothing
end

"Update constraints trajectories"
function update_constraints!(C::PartedVecTrajectory{T},constraints::ProblemConstraints,
        X::VectorTrajectory{T},U::VectorTrajectory{T}) where T
    N = length(X)
    for k = 1:N-1
        evaluate!(C[k],constraints[k],X[k],U[k])
    end
    evaluate!(C[N],constraints[N],X[N])
end


"Evaluate active set constraints for entire trajectory"
function update_active_set!(a::PartedVecTrajectory{Bool},c::PartedVecTrajectory{T},λ::PartedVecTrajectory{T},tol::T=0.0) where T
    N = length(c)
    for k = 1:N
        active_set!(a[k], c[k], λ[k], tol)
    end
end

function update_active_set!(obj::AugmentedLagrangianObjective{T},tol::T=0.0) where T
    update_active_set!(obj.active_set,obj.C,obj.λ,tol)
end

"Evaluate active set constraints for a single time step"
function active_set!(a::AbstractVector{Bool}, c::AbstractVector{T}, λ::AbstractVector{T}, tol::T=0.0) where T
    # inequality_active!(a,c,λ,tol)
    a.equality .= true
    a.inequality .=  @. (c.inequality >= tol) | (λ.inequality > 0)
    return nothing
end

function active_set(c::AbstractVector{T}, λ::AbstractVector{T}, tol::T=0.0) where T
    a = BlockArray(trues(length(c)),c.parts)
    a.equality .= true
    a.inequality .=  @. (c.inequality >= tol) | (λ.inequality > 0)
    return a
end

"Cost function terms for Lagrangian and quadratic penalty"
function aula_cost(a::AbstractVector{Bool},c::AbstractVector{T},λ::AbstractVector{T},μ::AbstractVector{T}) where T
    λ'c + 1/2*c'Diagonal(a .* μ)*c
end

function stage_constraint_cost(obj::AugmentedLagrangianObjective{T},x::AbstractVector{T},u::AbstractVector{T},k::Int) where T
    c = obj.C[k]
    λ = obj.λ[k]
    μ = obj.μ[k]
    a = obj.active_set[k]
    aula_cost(a,c,λ,μ)
end

function stage_constraint_cost(obj::AugmentedLagrangianObjective{T},x::AbstractVector{T}) where T
    c = obj.C[end]
    λ = obj.λ[end]
    μ = obj.μ[end]
    a = obj.active_set[end]
    aula_cost(a,c,λ,μ)
end

function stage_constraint_cost(c,λ,μ,
        a,x::AbstractVector{T},u::AbstractVector{T}) where T
    aula_cost(a,c,λ,μ)
end

function stage_constraint_cost(c,λ,μ,
        a,x::AbstractVector{T}) where T
    aula_cost(a,c,λ,μ)
end

"Augmented Lagrangian cost for X and U trajectories"
function cost(obj::AugmentedLagrangianObjective{T},X::VectorTrajectory{T},U::VectorTrajectory{T}) where T <: AbstractFloat
    N = length(X)
    J = cost(obj.cost,X,U)

    update_constraints!(obj.C,obj.constraints, X, U)
    update_active_set!(obj)

    Jc = 0.0
    for k = 1:N-1
        Jc += stage_constraint_cost(obj.C[k], obj.λ[k], obj.μ[k],obj.active_set[k],X[k],U[k])
    end
    Jc /= (N-1.0)

    Jc += stage_constraint_cost(obj.C[N], obj.λ[N], obj.μ[N],obj.active_set[N],X[N])

    return J + Jc
end
