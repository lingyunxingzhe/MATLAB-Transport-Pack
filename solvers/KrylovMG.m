%> @file  KrylovMG.m
%> @brief KrylovMG class definition.
% ==============================================================================
%> @brief  Krylov multigroup solver.
%
%> Traditionally, the Gauss-Seidel method has been used for multigroup problems.
%> For each group, the within-group equation is solved, and the the fluxes are
%> updated for use in the next group.  However, for problems with significant
%> upscatter, Gauss-Seidel can be quite expensive, even when GMRES (or some
%> better-than-source-iteration) is used for the within group solve.  As an
%> alternativel, we can apply GMRES (or other Krylov solvers) to the multigroup
%> problem directly.  The linear system is then
%> \f[
%>     \left( ( \mathbf{I} -
%>         \left(\begin{array}{ccc}   
%>             T_1  & \cdots & 0     \\ 
%>             0    & \ddots & 0     \\ 
%>             0    & 0      & T_G   
%>         \end{array}\right) \cdot
%>         \left(\begin{array}{ccc}   
%>             M    & \cdots & 0     \\ 
%>             0    & \ddots & 0     \\ 
%>             0    & 0      & M     
%>         \end{array}\right) \cdot
%>         \left(\begin{array}{ccc}   
%>            \mathbf{S}_{11} & \cdots & \mathbf{S}_{1G} \\ 
%>            \vdots          & \ddots & \vdots          \\ 
%>            \mathbf{S}_{G1} & 0      & \mathbf{S}_{GG} 
%>         \end{array}\right)
%>     \right ) \cdot
%>     \left[ \begin{array}{c} 
%>         \phi_1 \\ 
%>         \vdots \\ 
%>         \phi_G 
%>     \end{array} \right] =
%>     \left[ \begin{array}{c} 
%>          \mathbf{T}_1 q_1 \\ 
%>          \vdots \\  
%>          \mathbf{T}_G q_G 
%>     \end{array} \right] \, .
%> \f]
%> Of course, this can be written succinctly the same way we did the within-
%> group equation:
%> \f[
%>     (\mathbf{I}-\mathbf{TMS})\phi = \mathbf{T}q \, ,
%> \f]
%> where \f$ \mathbf{T} = D\mathbf{L}^{-1} \f$ is the sweeping operator with
%> moment contributions added implicitly, and where the Krylov vectors are 
%> energy-dependent.
%>
%> Note, this inherits from @ref InnerIteration since we need all its properties
%> and do not add much that isn't already there.
%>
%> Reference:
%>   Evans, T., Davidson, G. and Mosher, S. "Parallel Algorithms for 
%>   Fixed-Source and Eigenvalue Problems", NSTD Seminar (ORNL), May 27, 2010.
% ==============================================================================

classdef KrylovMG < InnerIteration
    
    properties
        %> Scaling factor for fixed source multiplication problems.
        d_keff = 1.0;
        %> Is this a straight fixed source problem *or* within eigensolve?
        d_fixed = 1;
        %>
        d_diffop
        %>
        d_pc = 0
        %>
        d_apply_m = []        
    end
    
    methods

        % ======================================================================
        %> @brief Class constructor
        %
        %> @param input             User input.
        %> @param state             State vectors.
        %> @param boundary          Boundary flux container.
        %> @param mesh              Geometry.
        %> @param mat               Material database.
        %> @param quadrature        Angular mesh.
        %> @param external_source 	Fixed source.
        %> @param fission_source 	Fission source.
        %>
        %> @return Instance of the KrylovMG class.
        % ======================================================================
        function this = KrylovMG(input,            ...
                                 state,            ...
                                 boundary,         ...
                                 mesh,             ...
                                 mat,              ...
                                 quadrature,       ...
                                 external_source,  ...
                                 fission_source,   ...
                                 fixed)

            % First do base class setup.  This builds the scattering
            % matrices, etc.
            setup_base( this,              ...
                        input,            ...
                        state,            ...
                        boundary,         ...
                        mesh,             ...
                        mat,              ...
                        quadrature,       ...
                        external_source,  ...
                        fission_source);
                    
            % Is this a fixed source problem or within an eigensolve?
            if exist('fixed', 'var')
                this.d_fixed = fixed;
            end
            
            % Reflection not incorporated for Krylov yet...
            if (strcmp(get(input, 'bc_left'),   'reflect')) || ...
               (strcmp(get(input, 'bc_right'),  'reflect')) || ...
               (strcmp(get(input, 'bc_bottom'), 'reflect')) || ...
               (strcmp(get(input, 'bc_top'),    'reflect')) || ...
               (strcmp(get(input, 'bc_south'),  'reflect')) || ...
               (strcmp(get(input, 'bc_north'),  'reflect')) 
               error('user:input','Krylov not ready for reflection!')
            end
           
            if input.get('outer_precondition')
                this.d_pc = 1;
                this.d_diffop = ...
                    DiffusionOperator(input, mat, mesh);
                this.d_apply_m = @(x)apply_m(x, this);
            end
                
        end
        
        % ======================================================================
        %> @brief Set scaling factor for fixed source multiplication problems.
        % ======================================================================
        function set_keff(this, k)
            this.d_keff = k; 
        end

        % ======================================================================
        %> @brief Solve the multigroup fixed source problem.
        %> @return Output, including error and iteration count.
        % ======================================================================
        function output = solve(this)

            % Set the boundary conditions.
            set(this.d_boundary);  
            
            % Setup.
            n = number_cells(this.d_mesh);
            ng = number_groups(this.d_mat);
           
            for g = 1:ng
                set_group(this.d_boundary, g); % Set the group
                set(this.d_boundary);
                set_group(this.d_boundary, g); % Set the group
                %
                % Setup the equations for this group.
                setup_group(this.d_equation, g);
                % Build the fixed source.
                sweep_source = build_fixed_sweep_source(this, g);
                % Compute the uncollided flux (i.e. RHS)
                B((g-1)*n+1:g*n, 1) = sweep(this.d_sweeper, sweep_source, g);
            end 
            % Set the boundaries to zero for the sweeps.
            reset(this.d_boundary);

            [phi, flag, flux_error, iter] = ...
                gmres(@(x)apply(x, this),   ... % Function to apply operator
                B,                          ... % right hand side
                20,                         ... % restart
                this.d_tolerance,           ... % tolerance
                40,                         ... % maxit (maxit*restart = total # applications)
                this.d_apply_m,             ... % left pc
                [],                         ... % right pc
                B                           );  % initial guess
            
            phi = reshape(phi, n, ng);
            for g = 1:ng
                set_phi(this.d_state, phi(:, g), g);
            end
            
            % Final sweep to update boundaries... a HACK!
            for g = 1:ng
                %set_group(this.d_boundary, g); % Set the group
                set(this.d_boundary);
                set_group(this.d_boundary, g); % Set the group
                setup_group(this.d_equation, g);
                
                % Add all scattering and then fixed.
                q = build_total_scatter_source(this.d_scatter_source, g, phi);
                sweep_source = q;%this.d_M.apply(q);
                sweep_source = sweep_source + build_fixed_sweep_source(this, g);
                    
                % Update.
                phi(:,g) = sweep(this.d_sweeper, sweep_source, g);
            end 
            
            switch flag
                case 0
                    % Okay.
                case 1
                     warning('solver:convergence', ...
                         'GMRES iterated MAXIT times without converging.')
                case 2
                     warning('solver:convergence', ...
                         'GMRES preconditioner was ill-conditioned.')
                case 3
                     warning('solver:convergence', 'GMRES stagnated.')
                otherwise
                    error('GMRES returned unknown flag.')
            end

            if (get(this.d_input, 'inner_print_out'))
                fprintf('        MG GMRES Outers: %5i,  Inners: %5i\n', ...
                    iter(1), iter(2));
            end
            
            iteration = iter(1) * iter(2);

            output.flux_error   = flux_error;
            output.total_inners = iteration;
        end
        
        % ======================================================================
        %> @brief Build fixed source from fission and/or external sources.
        %
        %> @param   g       Group for this problem.
        % ======================================================================        
        function q = build_fixed_sweep_source(this, g)           
            q = 0;
            % Add the fission source if required and if we won't be pulling
            % it to the left hand side in a fixed source problem.
            if (this.d_fixed && initialized(this.d_fission_source))
                q = q + source(this.d_fission_source, g);
            end   
            % Add the external source if present.
            if (initialized(this.d_external_source))
            	q = q + source(this.d_external_source, g);   
            end   
            %q = this.d_M.apply(q);
        end
        
        % ======================================================================
        %> @brief Build all scatter sweep source.
        %>
        %> This is intended for fixed source problems with multiplication.
        %>
        %> @param   g       Group for this problem.  (I.e. row in MG).
        %> @param   phi     Current MG flux.
        % ======================================================================
        function q = build_all_scatter_sweep_source(this, g, phi)
            q = build_total_scatter_source(this.d_scatter_source, g, phi);
            %q = this.d_M.apply(q); 
        end % build_fission_source   
  
        
    end

    methods (Access = protected)

        function print_iteration(this, iteration, flux_error, total_inners)
            if (get(this.d_input, 'print_out'))
                fprintf(...
                    '-------------------------------------------------------\n')
                fprintf('       Iter: %5i, Error: %12.8f, Inners: %5i\n',...
                    iteration, flux_error, total_inners);
                fprintf(...
                    '-------------------------------------------------------\n')
            end
        end
        
    end

end


% ======================================================================
%> @brief Apply the multigroup transport operator.
%> @return Matrix-vector
% ======================================================================
function y = apply(x, this)


    % Number of unknowns per group
    n   = number_cells(this.d_mesh);
    ng  = number_groups(this.d_mat);
    % Store the incoming Krylov vector
    phi = reshape(x,n,ng);
    y   = 0*phi;
    % Build the application of
    %
    %   |   I-T*M*S_11    -T*M*S_12    -T*M*S_13   ... | |phi_1|   |b_1|
    %   |    -T*M*S_21   I-T*M*S_22    -T*M*S_23   ... |*|phi_2| = |b_2|
    %   |    ...                                       | |phi_3|   |b_3|
    %
    % where T = D*inv(L), D is the discrete to moments operator, and inv(L)
    % is the space-angle sweep.
    
    % Update fission source with this Krylov vector if this is a fixed 
    % source problem
    if (this.d_fixed && initialized(this.d_fission_source))
        for g = 1:ng
            set_phi(this.d_state, phi(:, g), g);
        end
        update(this.d_fission_source);
        setup_outer(this.d_fission_source, 1/this.d_keff);
    end
    
    for g = 1:ng

        % Setup some constants for this group.
        setup_group(this.d_equation, g);
        
        % Update incident boundary fluxes.
        set_group(this.d_boundary, g);
        update(this.d_boundary);
        
        % Build all scattering sources.  This included all scatter from any
        % group g' into any group g ( within-group scatter is included).
        sweep_source = build_all_scatter_sweep_source(this, g, phi);
        
        % Only add fission if this is a multiplying fixed source problem.
        % Otherwise, this is an eigenproblem for which the fission is an
        % *external* source.
        if (this.d_fixed && initialized(this.d_fission_source))
            % Get the group gp fission source.
            f = source(this.d_fission_source, g);
            % Add it.  This *assumes* the fission source returns a
            % vector prescaled to serve as a discrete source.
            sweep_source = sweep_source + f;
        end
        
        % Sweep over all angles and meshes.  This is equivalent to
        %   y <-- D*inv(L)*M*S*x
        y(:, g) = sweep(this.d_sweeper, sweep_source, this.d_g);

        % Now, return the following
        % y <-- x - D*inv(L)*M*S*x = (I - D*inv(L)*M*S)*x
        y(:, g) = phi(:, g) - y(:, g);

    end
    
    % Restore to 1-d form
    y = reshape(y, n*ng, 1);
  
end

%> @brief Apply one-group diffusion preconditioner.
function y = apply_m(x, this)

% Our preconditioner is
% (I + inv(C)S)


% Number of unknowns per group
n   = number_cells(this.d_mesh);
ng  = number_groups(this.d_mat);

% Store the incoming Krylov vector
y  = reshape(x,n,ng);
y2 = 0*y;


% Update fission source if this is a fixed source problem.
if (this.d_fixed && initialized(this.d_fission_source))
    for g = 1:ng
        set_phi(this.d_state, y(:, g), g);
    end
    update(this.d_fission_source);
    setup_outer(this.d_fission_source, 1/this.d_keff);
end

for g = 1:ng
    % Get one group diffusion operator.
    M = this.d_diffop.get_1g_operator(g);
    % Build all scattering sources.  
    q = build_total_scatter_source(this.d_scatter_source, g, y);
    % Add fission if this is a multiplying fixed source problem.
    if (this.d_fixed && initialized(this.d_fission_source))
        q = q + source(this.d_fission_source, g);
    end
    % Solve.
    y2(:, g) = y(:, g) + M \ q;
end

y = reshape(y2, n*ng, 1);

end