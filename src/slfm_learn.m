function [elbo,par] = slfm_learn(x,y,M,par,cf)
%SLFM_LEARN slfm_learn(x,y,M,cf)
%   Quick wrapper to run structured GPSVI.
% 
% INPUT
%   - x,y : train inputs, train outputs
%   - M : #inducing inputs
%   - cf : configuration
%
% OUTPUT
%   - elbo : the bound
%   - params : learned parameters
[N D] = size(x);
% get observation indice for each output
P = numel(par.task); Q = numel(par.g);
par.w = cf.w;
par.delta_w = zeros(P,Q);
par.beta = cf.beta*ones(P,1);
par.delta_beta = zeros(P,1);
observed = ~isnan(y);
nhyper_g = eval(feval(cf.covfunc_g));
ytmp = y;
for i=1:P
  yi = y(observed(:,i),i);
  ytmp(~observed(:,i),i) = mean(yi);
end
ymean = mean(ytmp,2);
for j=1:Q
  par.g{j} = init_params(par.g{j},x,ymean,M.g,nhyper_g,initz(x,M.g,cf.initz));
  par.g{j}.m = zeros(size(par.g{j}.m));
end
nhyper_h = eval(feval(cf.covfunc_h));
for i=1:P
  par.task{i} = init_params(par.task{i},x,y(:,i),M.h,nhyper_h,initz(x,M.h,cf.initz));
  par.task{i}.m = zeros(size(par.task{i}.m));
end

elbo = zeros(cf.maxiter,1);
for iter = 1:cf.maxiter
  idx = randperm(N, cf.nbatch);
  par.idx = ~isnan(y(idx,:));
  xbatch = x(idx,:); ybatch = y(idx,:);
  
  % variational parameters of g_j
  par = slfm_update_g(xbatch,ybatch,par,cf);
  
  if iter > N/cf.nbatch || ~cf.fix_first 
    % hyperparameters of g_j
    [~,dbeta,dw,dloghyp] = slfm_elbo(xbatch,ybatch,par,cf);
    for j=1:Q
      [par.g{j}.loghyp,par.g{j}.delta_hyp] = stochastic_update(...
        par.g{j}.loghyp,par.g{j}.delta_hyp,dloghyp{j},cf.momentum,cf.lrate_hyp);
    end

    % update w, beta
    dw = reshape(cell2mat(dw),P,Q);
    [par.w,par.delta_w] = stochastic_update(par.w,par.delta_w,dw,cf.momentum_w,cf.lrate_w);
    [par.beta,par.delta_beta] = stochastic_update(par.beta,par.delta_beta,dbeta,cf.momentum,cf.lrate_beta);

    % update inducing of g (using new hyperparameters)
    if cf.learn_z
      [~,~,~,~,dz] = slfm_elbo(xbatch,ybatch,par,cf);
      for j=1:Q
        [par.g{j}.z,par.g{j}.delta_z] = stochastic_update(...
          par.g{j}.z,par.g{j}.delta_z,dz{j},cf.momentum_z,cf.lrate_z);
      end
    end

    % pre-computation to update h_i
    wAm = cell(P,1); % wAm{i} = \sum_j w_ij A_j(oi) m_j
    for j=1:Q
      Aj = computeKnmKmminv(cf.covfunc_g, par.g{j}.loghyp, x, par.g{j}.z);
      for i=1:P
        indice = par.idx(:,i);
        w = par.w(i,j);
        if isempty(wAm{i})
          wAm{i} = w*Aj(indice,:)*par.g{j}.m;
        else
          wAm{i} = wAm{i} + w*Aj(indice,:)*par.g{j}.m;
        end
      end
    end

    % update h_i
    for i=1:P
      indice = par.idx(:,i);
      y0 = ybatch(indice,i) - wAm{i};
      par.task{i}.beta = par.beta(i);
      % variational parameters of h_i
      par.task{i} = svi_update(xbatch(indice,:),y0,par.task{i},cf,cf.covfunc_h);
      % hyperparameters of h_i
      [~,dloghyp,~] = svi_elbo(xbatch(indice,:),y0,par.task{i},cf.covfunc_h);
      [par.task{i}.loghyp,par.task{i}.delta_hyp] = stochastic_update(...
        par.task{i}.loghyp,par.task{i}.delta_hyp,dloghyp,cf.momentum,cf.lrate_hyp);
      % inducing of h_i (using new hyperparameters)
      if cf.learn_z
        [~,~,~,dz] = svi_elbo(xbatch(indice,:),y0,par.task{i},cf.covfunc_h);
      [par.task{i}.z,par.task{i}.delta_z] = stochastic_update(...
        par.task{i}.z,par.task{i}.delta_z,dz,cf.momentum_z,cf.lrate_z);
      end
    end
  end
  
%   disp('par.w = ')
%   disp(par.w')
%   disp('min, max g.m')
%   disp([min(par.g{1}.m), max(par.g{1}.m)])
  
  % global elbo for checking convergence
  if ~isempty(cf.monitor_elbo) && mod(iter,cf.monitor_elbo) == 0
    nn = ceil(N/2000);
    for i=1:nn-1
      indice = ((i-1)*2000+1):(i*2000);
      par.idx = ~isnan(y(indice,:));
      elbo(iter) = elbo(iter) + slfm_elbo(x(indice,:),y(indice,:),par,cf);
    end
    indice = ((nn-1)*2000+1):N;
    par.idx = ~isnan(y(indice,:));
    elbo(iter) = elbo(iter) + slfm_elbo(x(indice,:),y(indice,:),par,cf);
    fprintf('Iteration\t%d:\t%.4f\n',iter,elbo(iter));
  else
    disp(['iter ' num2str(iter)]);
  end
  
end
end

