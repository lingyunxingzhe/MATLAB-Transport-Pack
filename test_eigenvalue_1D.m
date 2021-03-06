%> @file  test_eigenvalue_1D.m
%> @brief Tests the eigenvalue solver on a 1D mesh.
%
% Ilas cites the following results (S4):
%
%   Assembly     kinf
%   ========   =========
%      A       1.330098
%      B       1.299289
%      C       0.679513
%      D       0.191268
%
%   Core     keff
%   =====   =========
%     1     1.258874
%     2     1.006969
%     3     0.804291
%
% ==============================================================================

clear

% ==============================================================================
% INPUT
% ==============================================================================
input = Input();
put(input, 'number_groups',         2);
put(input, 'eigen_tolerance',       1e-6);
put(input, 'eigen_max_iters',       100);
put(input, 'inner_tolerance',       0.00001);
put(input, 'inner_solver',          'SI');
put(input, 'livolant_free_iters',   3);
put(input, 'livolant_accel_iters',  3);
input.number_groups = 2;
put(input, 'bc_left',               'vacuum');
put(input, 'bc_right',              'vacuum');

% ==============================================================================
% MATERIALS (Test two group data)
% ==============================================================================
mat = test_materials(2);


% ==============================================================================
% MESH (The simple slab reactors from Mosher's thesis)
% ==============================================================================

% Assembly coarse mesh edges
base   = [ 1.1580 4.4790 7.8000 11.1210 14.4420 15.6000 ]; 
% and fine mesh counts.
basef  = [ 1 2 2 2 2 1 ]*4; 
% Several such assemblies to make the total coarse mesh definition
xcm_c  = [ 0.0  base  base+15.6  base+15.6*2 base+15.6*3 ...
           base+15.6*4 base+15.6*5 base+15.6*6 ];
xfm_c  = [ basef basef basef basef basef basef basef ];
xcm_a  = [ 0 base];
xfm_a  = basef;

% Assembly types
assem_A    = [ 1 2 3 3 2 1 ];
assem_B    = [ 1 2 2 2 2 1 ];
assem_C    = [ 1 2 4 4 2 1 ];
assem_D    = [ 1 4 4 4 4 1 ];

% Cores 1, 2 and 3
core_1 = [ assem_A assem_B assem_A assem_B assem_A assem_B assem_A ];
core_2 = [ assem_A assem_C assem_A assem_C assem_A assem_C assem_A ];
core_3 = [ assem_A assem_D assem_A assem_D assem_A assem_D assem_A ];


mesh = Mesh1D(xfm_c, xcm_c, core_1);


% ==============================================================================
% SETUP 
% ==============================================================================
state       = State(input, mesh);
quadrature  = GaussLegendre(4);
boundary    = BoundaryMesh(input, mesh, quadrature);
q_e         = Source(mesh, 2);                  % Not initialized = not used.
q_f         = FissionSource(state, mesh, mat);  % Inititalized = used.
initialize(q_f);

% ==============================================================================
% SOLVE 
% ==============================================================================
solver = Eigensolver(input,         ...
                     state,         ...
                     boundary,      ...
                     mesh,          ...
                     mat,           ...
                     quadrature,	...
                     q_e,           ...
                     q_f);
 
tic
out = solve(solver); 
toc

% ==============================================================================
% POSTPROCESS 
% ==============================================================================

% subplot(2, 1, 1)
% f = flux(state, 1);
% plot_flux(mesh, f)
% subplot(2, 1, 2)
% f = flux(state, 2);
% plot_flux(mesh, f)
