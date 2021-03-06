#' QC check
#'
#' This function allows you to check the library size and detaction rate.
#' @param data_count Input count matrix.
#' @keywords qc
#' @export
#' @examples
#' \dontrun{
#'    qc_check(input_data)
#' }
qc_check <- function(data_count){
  library_size <- apply(data_count,2,sum)
  detected_gene_num <- apply(data_count,2,function(x)length(which(x>0)))
  return(list(library_size=library_size,detected_gene_num=detected_gene_num))
}

#' Get the nearest neighboring cells
#'
#' This function allows you to get the nunmber of nearest neighbor used for estimating dropout.
#' @param data_count Input count matrix.
#' @param gene_len_org A vector for the length of genes in coding regions
#' @param max_num Maximum number of nearest neighboring cells
#' @param scale_factor Global scale factor for normalizing the nearest neighboring cells
#' @keywords nearest neighbor
#' @export
get_expected_cell <- function(data_count,gene_len_org,max_num=20,scale_factor=1e6){

  if(max_num > ncol(data_count)){
    max_num <- ncol(data_count)
  }

  gene_len_scale <- ceiling(gene_len_org/1000)
  data_FPKM <- t(t(data_count/gene_len_scale)*scale_factor/apply(data_count,2,sum))
  data_dist <- as.matrix(dist(t(data_FPKM)))
  data_expect <- matrix(data=NA,ncol=ncol(data_count),nrow=nrow(data_count))

  if(max_num==1){
    for(j in 1:ncol(data_FPKM)){
      nearest_cell_idx <- sort(data_dist[j,],decreasing=FALSE,index.return=TRUE)$ix[2]
      data_expect[,j] <- data_FPKM[,nearest_cell_idx]
    }
  }
  else{
    sim_stat <- list()
    sim_stat[[1]] <- rep(NA,ncol(data_FPKM))
    for(j in 1:ncol(data_FPKM)){
      nearest_cell_idx <- sort(data_dist[j,],decreasing=FALSE,index.return=TRUE)$ix[2]
      data_neighbor <- data_FPKM[,nearest_cell_idx]
      sim_stat[[1]][j] <- cor(data_FPKM[,j],data_neighbor)
    }

    for(i in 2:max_num){
      sim_stat[[i]] <- rep(NA,ncol(data_FPKM))
      for(j in 1:ncol(data_FPKM)){
        nearest_cell_idx <- sort(data_dist[j,],decreasing=FALSE,index.return=TRUE)$ix[2:(i+1)]
        data_neighbor <- apply(data_FPKM[,nearest_cell_idx],1,mean)
        sim_stat[[i]][j] <- cor(data_FPKM[,j],data_neighbor)
      }
    }

    sim_stat_combine <- do.call(cbind,sim_stat)
    sim_stat_mean <- apply(sim_stat_combine,2,mean)
    sim_stat_mean_diff <- diff(sim_stat_mean)

    x <- 1:length(sim_stat_mean_diff)
    neighbor_num <- which.min(sapply(x, function(k) {
      x2 <- pmax(0,x-k)
      sum(lm(sim_stat_mean_diff~x+x2)$residuals^2)
    }))
    neighbor_num <- neighbor_num + 1

    for(j in 1:ncol(data_FPKM)){
      nearest_cell_idx <- sort(data_dist[j,],decreasing=FALSE,index.return=TRUE)$ix[2:neighbor_num]
      data_expect[,j] <- apply(data_FPKM[,nearest_cell_idx],1,mean)
    }

  }

  return(list(data_expect=data_expect,neighbor_num=neighbor_num))

}

##estimate dropout with a small poisson for the dropout component
#' This function is used for estimating dropout probability.
#' @param sc_data Input count matrix.
#' @param sc_data_expect Gene expression from the pool neighboring cells obtained by function get_expected_cell
#' @export
estimate_drop_out <- function(sc_data,sc_data_expect,gene_len_org,per_tile_beta=6,per_tile_tau=6,alpha_init=c(1,-1),spois_init=0.1,beta_init=c(0.1,0.1,0.1),tau_init=c(0.1,-0.1,-0.1),em_error_par=0.01,em_min_count=1,em_max_count=30,trace_flag=0){
  
  gene_len <- ceiling(gene_len_org/1000)
  data_observe <- sc_data
  data_mui <- log(sc_data_expect+1)
  N_beta <- per_tile_beta
  N_tau <- per_tile_tau
  #data_mui_percentile_beta <- quantile(data_mui[which(data_mui>0)],seq(1/N_beta,(N_beta-1)/N_beta,1/N_beta))
  #data_mui_percentile_tau <- quantile(data_mui[which(data_mui>0)],seq(1/N_tau,(N_tau-1)/N_tau,1/N_tau))
  data_mui_percentile_beta <- (max(data_mui)/N_beta)*c(1:N_beta)
  data_mui_percentile_tau <- (max(data_mui)/N_tau)*c(1:N_tau)
  
  ##generate spline matrix for beta
  spline_mat_beta <- matrix(data=0,nrow=N_beta+3,ncol=length(data_observe))
  spline_mat_beta[1,] <- 1
  spline_mat_beta[2,] <- data_mui
  spline_mat_beta[3,] <- data_mui^2
  spline_mat_beta[4,] <- data_mui^3
  
  for(i in 5:(N_beta+3)){
    select_idx <- which(data_mui > data_mui_percentile_beta[i-4])
    spline_mat_beta[i,select_idx] <- (data_mui[select_idx]-data_mui_percentile_beta[i-4])^3
  }
  
  ##generate spline matrix for tau
  spline_mat_tau <- matrix(data=0,nrow=N_tau+3,ncol=length(data_observe))
  spline_mat_tau[1,] <- 1
  spline_mat_tau[2,] <- data_mui
  spline_mat_tau[3,] <- data_mui^2
  spline_mat_tau[4,] <- data_mui^3
  
  for(i in 5:(N_tau+3)){
    select_idx <- which(data_mui > data_mui_percentile_tau[i-4])
    spline_mat_tau[i,select_idx] <- (data_mui[select_idx]-data_mui_percentile_tau[i-4])^3
  }
  
  ##generate constrain matrix for beta
  data_mui_uni <- unique(data_mui)
  
  cons_mat <- matrix(data=0,nrow=N_beta+3,ncol=length(data_mui_uni))
  cons_mat[1,] <- 0
  cons_mat[2,] <- 1
  cons_mat[3,] <- 2*data_mui_uni
  cons_mat[4,] <- 3*data_mui_uni^2
  
  for(i in 5:(N_beta+3)){
    select_idx <- which(data_mui_uni > data_mui_percentile_beta[i-4])
    cons_mat[i,select_idx] <- 3*(data_mui_uni[select_idx]-data_mui_percentile_beta[i-4])^2
  }
  
  ##initialize parameters
  beta_k <- c(beta_init,rep(0,N_beta))
  tau_k <- c(tau_init,rep(0,N_tau))
  alpha_k <- alpha_init
  spois_k <- spois_init
  lamda_k <- exp(colSums(beta_k*spline_mat_beta))
  phi_k <- exp(colSums(tau_k*spline_mat_tau))
  step_count <- 1
  flag <- 0
  logLik_trace <- matrix(data=NA,nrow=em_max_count,ncol=2)
  em_trace <- 1
  em_trace_count <- 1
  alpha_trace <- matrix(data=NA,nrow=em_max_count,ncol=2)
  spois_trace <- matrix(data=NA,nrow=em_max_count,ncol=1)
  beta_trace <- matrix(data=NA,nrow=em_max_count,ncol=length(beta_k))
  tau_trace <- matrix(data=NA,nrow=em_max_count,ncol=length(tau_k))
  
  while(flag==0 && step_count <= em_max_count){
    
    cat(step_count, " of maximum ", em_max_count,"EM steps\n")
    flush.console()
    ##E step
    pi_k <- 1/(1+exp(-alpha_k[1]-alpha_k[2]*data_mui))
    drop_out_z_kp1 <- pi_k*dpois(data_observe,spois_k)/(pi_k*dpois(data_observe,spois_k) + (1-pi_k)*(1/(1+gene_len*lamda_k*phi_k))^(1/phi_k))
    drop_out_z_kp1[is.nan(drop_out_z_kp1)] <- 0
    
    logLik_trace[step_count,2] <- sum(drop_out_z_kp1*((alpha_k[1]+alpha_k[2]*data_mui) - log(1+exp(alpha_k[1]+alpha_k[2]*data_mui)) + dpois(data_observe,spois_k,log=TRUE)) + (1-drop_out_z_kp1)*(-log(1+exp(alpha_k[1]+alpha_k[2]*data_mui)))) + sum((lgamma(data_observe+1/phi_k)-lgamma(1/phi_k)-(data_observe+1/phi_k)*log(1+gene_len*lamda_k*phi_k)+data_observe*log(lamda_k*phi_k))*(1-drop_out_z_kp1)) + sum((1-drop_out_z_kp1)*(data_observe*log(gene_len)-lgamma(data_observe+1)))
    
    ##M step for alpha
    logi_fun <- function(alpha_est,drop_out_z_kp1_in,data_mui_in,data_observe_in){
      output <- sum(drop_out_z_kp1_in*((alpha_est[1]+alpha_est[2]*data_mui_in) - log(1+exp(alpha_est[1]+alpha_est[2]*data_mui_in)) + dpois(data_observe_in,alpha_est[3],log=TRUE)) + (1-drop_out_z_kp1_in)*(-log(1+exp(alpha_est[1]+alpha_est[2]*data_mui_in))))
      return(output)
    }
    
    opt_result_logi <- constrOptim(c(alpha_k,spois_k), f = logi_fun, grad = NULL, ui = rbind(c(0,0,1),c(0,0,-1)), ci = c(0,-1), control = list(fnscale = -1), drop_out_z_kp1_in = drop_out_z_kp1, data_mui_in = data_mui, data_observe_in = data_observe)
    alpha_k <- opt_result_logi$par[1:2]
    spois_k <- opt_result_logi$par[3]
    
    ##M step for beta
    spline_fun <- function(param_est,beta_k_in,spline_mat_beta_in,spline_mat_tau_in,data_mui_in,drop_out_z_kp1_in,data_observe_in,gene_len_in){
      beta_est <- param_est[c(1:length(beta_k_in))]
      tau_est <- param_est[-c(1:length(beta_k_in))]
      
      sc_lamda <- exp(colSums(beta_est*spline_mat_beta_in))
      sc_phi <- exp(colSums(tau_est*spline_mat_tau_in))
      
      output <- sum((lgamma(data_observe_in+1/sc_phi)-lgamma(1/sc_phi)-(data_observe_in+1/sc_phi)*log(1+gene_len_in*sc_lamda*sc_phi)+data_observe_in*log(sc_lamda*sc_phi))*(1-drop_out_z_kp1_in))
      return(output)
    }
    
    if(em_trace == 0){
      ##monotonic contrain on lamda
      if(em_trace_count == 1){
        beta_k <- c(beta_init,rep(0,N_beta))
      }
      opt_result <- constrOptim(c(beta_k,tau_k), f = spline_fun, grad = NULL, ui = t(rbind(cons_mat,matrix(data=0,nrow=N_tau+3,ncol=ncol(cons_mat)))), ci = rep(0,ncol(cons_mat)), control = list(fnscale = -1), beta_k_in = beta_k, spline_mat_beta_in = spline_mat_beta, spline_mat_tau_in = spline_mat_tau, data_mui_in = data_mui, drop_out_z_kp1_in = drop_out_z_kp1, data_observe_in = data_observe, gene_len_in = gene_len)
      em_trace_count <- em_trace_count + 1
    }else{
      ##without constrain on lamda
      opt_result <- optim(c(beta_k,tau_k), fn = spline_fun, gr = NULL, beta_k,spline_mat_beta,spline_mat_tau,data_mui,drop_out_z_kp1,data_observe,gene_len,method = "Nelder-Mead",control = list(fnscale = -1))
    }
    
    param_k <- opt_result$par
    beta_k <- param_k[c(1:length(beta_k))]
    tau_k <- param_k[-c(1:length(beta_k))]
    
    lamda_k <- exp(colSums(beta_k*spline_mat_beta))
    phi_k <- exp(colSums(tau_k*spline_mat_tau))
    
    logLik_trace[step_count,1] <- opt_result_logi$value + opt_result$value + sum((1-drop_out_z_kp1)*(data_observe*log(gene_len)-lgamma(data_observe+1)))
    
    alpha_trace[step_count,] <- alpha_k
    spois_trace[step_count,] <- spois_k
    beta_trace[step_count,] <- beta_k
    tau_trace[step_count,] <- tau_k
    
    ##stop if converged
    if(step_count > em_min_count && em_trace_count > 2 && ((abs((logLik_trace[step_count,1] - logLik_trace[step_count-1,1])/logLik_trace[step_count-1,1]) < em_error_par) || (logLik_trace[step_count,1] < logLik_trace[step_count-1,1]))){
      flag <- 1
      message('EM converged in ',step_count,' steps')
      flush.console()
    }
    
    ##switch to constrOptim
    if(step_count > em_min_count && em_trace == 1 && ((abs((logLik_trace[step_count,1] - logLik_trace[step_count-1,1])/logLik_trace[step_count-1,1]) < em_error_par) || (logLik_trace[step_count,1] < logLik_trace[step_count-1,1]))){
      em_trace <- 0
    }
    
    step_count <- step_count + 1
  }
  
  alpha_out <- alpha_trace[step_count-1,]
  spois_out <- spois_trace[step_count-1,]
  beta_out <- beta_trace[step_count-1,]
  tau_out <- tau_trace[step_count-1,]
  
  lamda_out <- exp(colSums(beta_out*spline_mat_beta))
  phi_out <- exp(colSums(tau_out*spline_mat_tau))
  pi_out <- 1/(1+exp(-alpha_out[1]-alpha_out[2]*data_mui))
  
  drop_out_z_out <- pi_out*dpois(data_observe,spois_out)/(pi_out*dpois(data_observe,spois_out) + (1-pi_out)*(1/(1+gene_len*lamda_out*phi_out))^(1/phi_out))
  drop_out_z_out[is.nan(drop_out_z_out)] <- 0
  
  ##get true expression
  data_true_out <- ((data_observe*phi_out+1)/(gene_len*phi_out+1/lamda_out))*(1 - drop_out_z_out) + spois_out*drop_out_z_out
  
  if(trace_flag==1){
    return(list(data_true=data_true_out,alpha_trace=alpha_trace,spois_trace=spois_trace,beta_trace=beta_trace,tau_trace=tau_trace,Loglik_trace=logLik_trace,
                spline_knot_beta_log=data_mui_percentile_beta,spline_knot_tau_log=data_mui_percentile_tau,post_weight=drop_out_z_out))
  }
  else{
    return(list(data_true=data_true_out,alpha_prior=alpha_out,spois_prior=spois_out,beta_prior=beta_out,tau_prior=tau_out,spline_knot_beta_log=data_mui_percentile_beta,
                spline_knot_tau_log=data_mui_percentile_tau,post_weight=drop_out_z_out))
  }
  
}

##estimate drop out wrap up
#' @importFrom parallel mclapply
#' @importFrom parallel splitIndices
#' @export
estimate_dropout_main <- function(sc_data_all,sc_data_expect_all,gene_len_org,ncore=1,per_tile_beta=6,per_tile_tau=6,alpha_init=c(1,-1),spois_init=0.1,beta_init=c(0.1,0.1,0.1),tau_init=c(0.1,-0.1,-0.1),em_error_par=0.01,em_min_count=1,em_max_count=30,trace_flag=0){

  if(ncore > 1){
    N <- ncol(sc_data_all) 
    iter_list <- splitIndices(N, N/ncore) 
    result <- list() 
    for(j in seq_along(iter_list)){ 
      iter_vec <- iter_list[[j]] 
      result[iter_vec] <- mclapply(iter_vec,function(i){estimate_drop_out(sc_data_all[,i],sc_data_expect_all[,i],gene_len_org,per_tile_beta,per_tile_tau,alpha_init,spois_init,beta_init,tau_init,em_error_par,em_min_count,em_max_count,trace_flag)},mc.cores=ncore) 
    }
  }
  else{
    result <- lapply(c(1:ncol(sc_data_all)),function(i){estimate_drop_out(sc_data_all[,i],sc_data_expect_all[,i],gene_len_org,per_tile_beta,per_tile_tau,alpha_init,spois_init,beta_init,tau_init,em_error_par,em_min_count,em_max_count,trace_flag)})
  }
  return(result)
}

##get weighted mean and variance
#' @export
get_weighted_stat <- function(data_in,weight_in){

	weight_norm <- weight_in/sum(weight_in)
	mean_weighted <- weighted.mean(data_in,weight_norm)
	var_weighted <- sum(weight_in*(data_in-mean_weighted)^2)/sum(weight_in)

	return(list(mean_weighted=mean_weighted,var_weighted=var_weighted))

}

##adjust library size
#' @export
adjust_library_size <- function(dropout_est,hp_gene,gene_names){

  match_idx <- match(gene_names,hp_gene)
  data_hp <- sapply(dropout_est,function(x) x$data_true[!is.na(match_idx)])
  data_hp_weight <- sapply(dropout_est,function(x) x$post_weight[!is.na(match_idx)])

  row_median <- apply(data_hp,1,median)
  select_idx <- which(row_median>0)

  data_hp_sub <- data_hp[select_idx,]
  data_hp_weight_sub <- 1 - data_hp_weight[select_idx,]

  data_stat_weighted <- sapply(c(1:nrow(data_hp_sub)),function(x) get_weighted_stat(data_hp_sub[x,],data_hp_weight_sub[x,]))
  data_mean_weighted <- unlist(data_stat_weighted[1,])

  reference_mean <- mean(data_mean_weighted)
  library_scale <- sapply(1:ncol(data_hp_sub),function(x) reference_mean/get_weighted_stat(data_hp_sub[,x],data_hp_weight_sub[,x])$mean_weighted)

  return(library_scale)
}

##permutation test for differential expression
#' @export
permutation_test_mean <- function(data_1,weight_1,data_2,weight_2,num_permute=1000){

  stat_1 <- get_weighted_stat(data_1,weight_1)
  stat_2 <- get_weighted_stat(data_2,weight_2)
  n1 <- length(data_1)
  n2 <- length(data_2)
  group_id <- c(rep(1,length(data_1)),rep(2,length(data_2)))
  test_org <- (stat_1$mean_weighted - stat_2$mean_weighted)/sqrt(stat_1$var_weighted/n1+stat_2$var_weighted/n2)
  data_combine <- c(data_1,data_2)
  weight_combine <- c(weight_1,weight_2)

  set.seed(12345)
  sample_mat <- t(sapply(1:num_permute,function(i) sample(group_id)))
  permut <- rep(NA,num_permute)
  
  for(id in 1:num_permute){

    sample_group <- sample_mat[id,]
    sample_data_1 <- data_combine[sample_group==1]
    sample_data_2 <- data_combine[sample_group==2]
    sample_weight_1 <- weight_combine[sample_group==1]
    sample_weight_2 <- weight_combine[sample_group==2]

    stat_1 <- get_weighted_stat(sample_data_1,sample_weight_1)
    stat_2 <- get_weighted_stat(sample_data_2,sample_weight_2)

    permut[id] <- (stat_1$mean_weighted - stat_2$mean_weighted)/sqrt(stat_1$var_weighted/n1+stat_2$var_weighted/n2)

  }

  pval_greater <- mean(test_org < permut)
  pval_less <- mean(test_org > permut)
  pval_ts <- mean(abs(test_org) < abs(permut))

  return(list(statistics=test_org,pval_greater=pval_greater,pval_less=pval_less,pval_ts=pval_ts))
}

##test differential expression wrap up
#' @title Differential mean test
#' @description This function is used for testing differential gene expression.
#' @param treatment_data Normalized count data for the treatment group
#' @param treatment_data_weight 1 - dropout probability for the treatment group
#' @param control_data Normalized count data for the control group
#' @param control_data_weight 1 - dropout probability for the control group
#' @param num_permute Number of permutation performed in the test
#' @param ncore Number of CPU cores used in the test
#' @param log_transform If TRUE, take log2 transformation after adding a pseudo count of 1 to the input data. Default TRUE.
#' @return 
#'  \item{statistics}{The weighted t-statistics}
#'  \item{pval_greater}{P-values for testing whether the expression of each gene in the treatment group is larger than that in the control group}
#'  \item{fdr_greater}{Adjusted p-values (FDR) of pval_greater}
#'  \item{pval_less}{P-values for testing whether the expression of each gene in the treatment group is smaller than that in the control group}
#'  \item{fdr_less}{Adjusted p-values (FDR) of pval_less}
#'  \item{pval_ts}{P-values for testing whether the expression of each gene in the treatment group is not equal to that in the control group}
#'  \item{fdr_ts}{Adjusted p-values (FDR) of pval_ts}
#' @keywords differential mean test
#' @examples 
#' \dontrun{
#' diff_expr <- test_mean_main(treatment_data_adjust,treatment_data_weight,control_data_adjust,control_data_weight,num_permute=10000,ncore=6,log_transform=TRUE)
#' write.csv(data.frame(match_gene_name,diff_expr),file="diff_expr.csv",row.names=FALSE)
#' }
#' @importFrom parallel mclapply
#' @importFrom parallel splitIndices
#' @export
test_mean_main <- function(treatment_data,treatment_data_weight,control_data,control_data_weight,num_permute=1000,ncore=1,log_transform=TRUE){
  
  treatment_data_weight <- treatment_data_weight/rowSums(treatment_data_weight)
  control_data_weight <- control_data_weight/rowSums(control_data_weight)
  
  if(log_transform==TRUE){
    treatment_data <- log2(treatment_data+1)
    control_data <- log2(control_data+1)
  }
  
  if(ncore > 1){
    N <- nrow(treatment_data) 
    iter_list <- splitIndices(N, N/ncore) 
    result <- list() 
    for(j in seq_along(iter_list)){ 
      iter_vec <- iter_list[[j]] 
      result[iter_vec] <- mclapply(iter_vec,function(i){permutation_test_mean(treatment_data[i,],treatment_data_weight[i,],control_data[i,],control_data_weight[i,],num_permute)},mc.cores=ncore) 
    }
  }
  else{
    result <- lapply(c(1:nrow(treatment_data)),function(i){permutation_test_mean(treatment_data[i,],treatment_data_weight[i,],control_data[i,],control_data_weight[i,],num_permute)})
  }
  
  result_combine <- do.call(rbind,result)
  result_combine <- apply(result_combine,2,unlist)
  result_out <- data.frame(result_combine,fdr_greater=p.adjust(result_combine[,2],method="fdr"),fdr_less=p.adjust(result_combine[,3],method="fdr"),fdr_ts=p.adjust(result_combine[,4],method="fdr"))
  return(result_out)
}

##permutation test for differential variance
#' @export
permutation_test_var <- function(data_1,weight_1,data_2,weight_2,num_permute=1000){

  stat_1 <- get_weighted_stat(data_1,weight_1)
  stat_2 <- get_weighted_stat(data_2,weight_2)
  n1 <- sum(weight_1)
  n2 <- sum(weight_2)
  group_id <- c(rep(1,length(data_1)),rep(2,length(data_2)))
  test_org <- stat_1$var_weighted/stat_2$var_weighted
  data_residual_combine <- c(data_1 - stat_1$mean_weighted,data_2 - stat_2$mean_weighted)
  weight_combine <- c(weight_1,weight_2)

  set.seed(12345)
  sample_mat <- t(sapply(1:num_permute,function(i) sample(group_id)))
  permut <- rep(NA,num_permute)
  
  for(id in 1:num_permute){

    sample_group <- sample_mat[id,]
    sample_data_1 <- data_residual_combine[sample_group==1]
    sample_data_2 <- data_residual_combine[sample_group==2]
    sample_weight_1 <- weight_combine[sample_group==1]
    sample_weight_2 <- weight_combine[sample_group==2]
    n1 <- sum(sample_weight_1)
    n2 <- sum(sample_weight_2)
    permut[id] <- (sum(sample_weight_1*(sample_data_1^2))/n1) / (sum(sample_weight_2*(sample_data_2^2))/n2)

  }

  pval_greater <- mean(test_org < permut)
  pval_less <- mean(test_org > permut)
  pval_ts <- (sum(max(test_org,1/test_org) < permut) + sum(min(test_org,1/test_org) > permut))/num_permute

  return(list(statistics=test_org,pval_greater=pval_greater,pval_less=pval_less,pval_ts=pval_ts))
}

##test differential variance wrap up
#' @title Differential variability test
#' @description This function is used for testing differential variability.
#' @param treatment_data Normalized count data for the treatment group
#' @param treatment_data_weight 1 - dropout probability for the treatment group
#' @param control_data Normalized count data for the control group
#' @param control_data_weight 1 - dropout probability for the control group
#' @param num_permute Number of permutation performed in the test
#' @param ncore Number of CPU cores used in the test
#' @param log_transform If TRUE, take log2 transformation after adding a pseudo count of 1 to the input data. Default TRUE.
#' @return 
#'  \item{statistics}{The weighted F-statistics}
#'  \item{pval_greater}{P-values for testing whether the variability of each gene in the treatment group is larger than that in the control group}
#'  \item{fdr_greater}{Adjusted p-values (FDR) of pval_greater}
#'  \item{pval_less}{P-values for testing whether the variability of each gene in the treatment group is smaller than that in the control group}
#'  \item{fdr_less}{Adjusted p-values (FDR) of pval_less}
#'  \item{pval_ts}{P-values for testing whether the variability of each gene in the treatment group is not equal to that in the control group}
#'  \item{fdr_ts}{Adjusted p-values (FDR) of pval_ts}
#' @keywords differential variability test
#' @examples 
#' \dontrun{
#' diff_var <- test_var_main(treatment_data_adjust,treatment_data_weight,control_data_adjust,control_data_weight,num_permute=10000,ncore=6,log_transform=TRUE)
#' write.csv(data.frame(match_gene_name,diff_var),file="diff_var.csv",row.names=FALSE)
#' }
#' @importFrom parallel mclapply
#' @importFrom parallel splitIndices
#' @export
test_var_main <- function(treatment_data,treatment_data_weight,control_data,control_data_weight,num_permute=1000,ncore=1,log_transform=TRUE){
  
  treatment_data_weight <- treatment_data_weight/rowSums(treatment_data_weight)
  control_data_weight <- control_data_weight/rowSums(control_data_weight)
  
  if(log_transform==TRUE){
    treatment_data <- log2(treatment_data+1)
    control_data <- log2(control_data+1)
  }
  
  if(ncore > 1){
    N <- nrow(treatment_data) 
    iter_list <- splitIndices(N, N/ncore) 
    result <- list() 
    for(j in seq_along(iter_list)){ 
      iter_vec <- iter_list[[j]] 
      result[iter_vec] <- mclapply(iter_vec,function(i){permutation_test_var(treatment_data[i,],treatment_data_weight[i,],control_data[i,],control_data_weight[i,],num_permute)},mc.cores=ncore) 
    }
  }
  else{
    result <- lapply(c(1:nrow(treatment_data)),function(i){permutation_test_var(treatment_data[i,],treatment_data_weight[i,],control_data[i,],control_data_weight[i,],num_permute)})
  }
  
  result_combine <- do.call(rbind,result)
  result_combine <- apply(result_combine,2,unlist)
  result_out <- data.frame(result_combine,fdr_greater=p.adjust(result_combine[,2],method="fdr"),fdr_less=p.adjust(result_combine[,3],method="fdr"),fdr_ts=p.adjust(result_combine[,4],method="fdr"))
  return(result_out)
}

##permutation test for anova
#' @export
permutation_test_anova <- function(data_in,weight_in,group_idx,num_permute=1000){
  
  stat_all <- get_weighted_stat(data_in,weight_in)
  stat_group <- lapply(unique(group_idx),function(x) {get_weighted_stat(data_in[group_idx==x],weight_in[group_idx==x])})
  
  n_all <- length(data_in)
  
  totalSS <- sum(weight_in*(data_in - stat_all$mean_weighted)^2)
  groupSS <- sapply(unique(group_idx),function(x) {sum(weight_in[group_idx==x]*(data_in[group_idx==x] - stat_group[[which(unique(group_idx)==x)]]$mean_weighted)^2)})
  
  test_org <- ((totalSS-sum(groupSS))/(length(unique(group_idx)) - 1 ))/(sum(groupSS)/(n_all - length(unique(group_idx))))
  
  set.seed(12345)
  sample_mat <- t(sapply(1:num_permute,function(i) sample(group_idx)))
  permut <- rep(NA,num_permute)
  
  for(id in 1:num_permute){
    
    sample_group <- sample_mat[id,]
    stat_group <- lapply(unique(sample_group),function(x) {get_weighted_stat(data_in[sample_group==x],weight_in[sample_group==x])})
    groupSS <- sapply(unique(sample_group),function(x) {sum(weight_in[sample_group==x]*(data_in[sample_group==x] - stat_group[[which(unique(sample_group)==x)]]$mean_weighted)^2)})
    permut[id] <- ((totalSS-sum(groupSS))/(length(unique(sample_group)) - 1 ))/(sum(groupSS)/(n_all - length(unique(sample_group))))

  }
  
  pval <- mean(test_org < permut)
  return(list(statistics=test_org,pval=pval))
}

##anova test wrap up
#' @importFrom parallel mclapply
#' @importFrom parallel splitIndices
#' @export
test_anova_main <- function(data_all,weight_all,group_idx,num_permute=1000,ncore=1){
  
  if(ncore > 1){
    N <- nrow(data_all) 
    iter_list <- splitIndices(N, N/ncore) 
    result <- list() 
    for(j in seq_along(iter_list)){ 
      iter_vec <- iter_list[[j]] 
      result[iter_vec] <- mclapply(iter_vec,function(i){permutation_test_anova(data_all[i,],weight_all[i,],group_idx,num_permute)},mc.cores=ncore) 
    }
  }
  else{
    result <- lapply(c(1:nrow(data_all)),function(i){permutation_test_anova(data_all[i,],weight_all[i,],group_idx,num_permute)})
  }
  return(result)
}

##get var, mean, and fitted var
#' @export
get_var_fit <- function(input_data,data_weight,span_param = 0.5){

	data_stat_weighted <- sapply(c(1:nrow(input_data)),function(x) get_weighted_stat(input_data[x,],data_weight[x,]))

	data_mean_weighted <- unlist(data_stat_weighted[1,])
	data_var_weighted <- unlist(data_stat_weighted[2,])

	data_reg <- data.frame(mean=log2(data_mean_weighted + 1),var=log2(data_var_weighted + 1))
	fitted_data <- loess(var ~ mean, data_reg,span=span_param)$fitted
	fitted_data[which(fitted_data < 0)] <- 0
	return(list(var_expect=fitted_data,mean=log2(data_mean_weighted + 1),var=log2(data_var_weighted + 1)))
}

##get estimates
#' @export
scdv_estimate <- function(treatment_data,treatment_data_weight,control_data,control_data_weight,span_param = 0.5){

	treatment_data <- as.matrix(treatment_data)
	control_data <- as.matrix(control_data)

	treatment_data_weight <- as.matrix(treatment_data_weight)
	control_data_weight <- as.matrix(control_data_weight)

	result_treatment <- get_var_fit(treatment_data,treatment_data_weight,span_param)
	var_expect_treatment <- result_treatment$var_expect
	mean_treatment <- result_treatment$mean
	var_treatment <- result_treatment$var

	result_control <- get_var_fit(control_data,control_data_weight,span_param)
	var_expect_control <- result_control$var_expect
	mean_control <- result_control$mean
	var_control <- result_control$var

	scale_factor_treatment <- var_treatment-var_expect_treatment
	scale_factor_control <- var_control-var_expect_control

	scale_factor_diff <- scale_factor_treatment - scale_factor_control

	return(list(scale_factor_treatment=scale_factor_treatment,scale_factor_control=scale_factor_control,
				var_expect_treatment=var_expect_treatment,var_expect_control=var_expect_control,
				mean_treatment=mean_treatment,mean_control=mean_control))
}


##check infinite data.frame
#' @export
is.infinite.data.frame <- function(obj){
    sapply(obj,FUN = function(x) all(is.infinite(x)))
}


##permute function
#' @export
scdv_permute <- function(treatment_data,treatment_data_weight,control_data,control_data_weight,var_expect_treatment,var_expect_control,num_permute = 1000){

	df_treatment <- ncol(treatment_data)
	df_control <- ncol(control_data)

	treatmeat_data_mean <- unlist(sapply(c(1:nrow(treatment_data)),function(x) get_weighted_stat(treatment_data[x,],treatment_data_weight[x,]))[1,])
	treatment_data_residual <- (treatment_data - treatmeat_data_mean)/sqrt(2^var_expect_treatment-1)
	treatment_data_residual[is.na(treatment_data_residual)] <- 0

	for(k in 1:ncol(treatment_data_residual)){
		treatment_data_residual[is.infinite(treatment_data_residual[,k]),k] <- 0
	}

	control_data_mean <- unlist(sapply(c(1:nrow(control_data)),function(x) get_weighted_stat(control_data[x,],control_data_weight[x,]))[1,])
	control_data_residual <- (control_data - control_data_mean)/sqrt(2^var_expect_control-1)
	control_data_residual[is.na(control_data_residual)] <- 0

	for(k in 1:ncol(control_data_residual)){
		control_data_residual[is.infinite(control_data_residual[,k]),k] <- 0
	}

	combine_data <- cbind(treatment_data_residual,control_data_residual)
	combine_data <- combine_data^2

	combine_weight <- cbind(treatment_data_weight,control_data_weight)

	treatment_data_sf_per <- matrix(data=NA,nrow=nrow(treatment_data),ncol=num_permute)
	control_data_sf_per <- matrix(data=NA,nrow=nrow(control_data),ncol=num_permute)

	pb = txtProgressBar(min = 0, max = num_permute, initial = 0, style = 3)

	set.seed(12345)
	for(i in 1:num_permute){

		setTxtProgressBar(pb,i)

		per_idx <- sample(c(1:(df_treatment+df_control)),df_treatment)

		treatment_data_var_per <- sapply(1:nrow(combine_data),function(x) sum(combine_data[x,per_idx]*combine_weight[x,per_idx]/sum(combine_weight[x,per_idx])))
		control_data_var_per <- sapply(1:nrow(combine_data),function(x) sum(combine_data[x,-per_idx]*combine_weight[x,-per_idx]/sum(combine_weight[x,-per_idx])))

		treatment_data_sf_per[,i] <- log2(treatment_data_var_per+1)
		control_data_sf_per[,i] <- log2(control_data_var_per+1)
	}

	close(pb)
	return(list(treatment_data_sf_per=treatment_data_sf_per,control_data_sf_per=control_data_sf_per))
}


##permute function multi-core
#' @importFrom parallel mclapply
#' @export
scdv_permute_mc <- function(treatment_data,treatment_data_weight,control_data,control_data_weight,var_expect_treatment,var_expect_control,num_permute = 1000,ncore = 4){

	df_treatment <- ncol(treatment_data)
	df_control <- ncol(control_data)

	treatmeat_data_mean <- unlist(sapply(c(1:nrow(treatment_data)),function(x) get_weighted_stat(treatment_data[x,],treatment_data_weight[x,]))[1,])
	treatment_data_residual <- (treatment_data - treatmeat_data_mean)/sqrt(2^var_expect_treatment-1)
	treatment_data_residual[is.na(treatment_data_residual)] <- 0

	for(k in 1:ncol(treatment_data_residual)){
		treatment_data_residual[is.infinite(treatment_data_residual[,k]),k] <- 0
	}

	control_data_mean <- unlist(sapply(c(1:nrow(control_data)),function(x) get_weighted_stat(control_data[x,],control_data_weight[x,]))[1,])
	control_data_residual <- (control_data - control_data_mean)/sqrt(2^var_expect_control-1)
	control_data_residual[is.na(control_data_residual)] <- 0

	for(k in 1:ncol(control_data_residual)){
		control_data_residual[is.infinite(control_data_residual[,k]),k] <- 0
	}

	combine_data <- cbind(treatment_data_residual,control_data_residual)
	combine_data <- combine_data^2

	combine_weight <- cbind(treatment_data_weight,control_data_weight)

	treatment_data_sf_per <- matrix(data=NA,nrow=nrow(treatment_data),ncol=num_permute)
	control_data_sf_per <- matrix(data=NA,nrow=nrow(control_data),ncol=num_permute)

	set.seed(12345)

	permute_fun <- function(i){

		per_idx <- sample(c(1:(df_treatment+df_control)),df_treatment)

		treatment_data_var_per <- sapply(1:nrow(combine_data),function(x) sum(combine_data[x,per_idx]*combine_weight[x,per_idx]/sum(combine_weight[x,per_idx])))
		control_data_var_per <- sapply(1:nrow(combine_data),function(x) sum(combine_data[x,-per_idx]*combine_weight[x,-per_idx]/sum(combine_weight[x,-per_idx])))

		treatment_data_sf_per_temp <- log2(treatment_data_var_per+1)
		control_data_sf_per_temp <- log2(control_data_var_per+1)
		return(list(treatment_data_sf_per_temp=treatment_data_sf_per_temp,control_data_sf_per_temp=control_data_sf_per_temp))
	}

	output_list <- mclapply(c(1:num_permute),permute_fun, mc.cores=ncore)
	
	for(i in 1:num_permute){
		treatment_data_sf_per[,i] <- output_list[[i]]$treatment_data_sf_per_temp
		control_data_sf_per[,i] <- output_list[[i]]$control_data_sf_per_temp
	}

	return(list(treatment_data_sf_per=treatment_data_sf_per,control_data_sf_per=control_data_sf_per))
}


##main function for differential hyper-variability analysis
#' @title Differential hyper-variability test
#' @description This function is used for testing differential hyper-variability.
#' @param treatment_data Normalized count data for the treatment group
#' @param treatment_data_weight 1 - dropout probability for the treatment group
#' @param control_data Normalized count data for the control group
#' @param control_data_weight 1 - dropout probability for the control group
#' @param num_permute Number of permutation performed in the test
#' @param span_param The span parameter in loess when fitting the mean-variance curve
#' @param ncore Number of CPU cores used in the test
#' @return 
#'  \item{sf_treatment}{The hyper-variability statistics for the treatment group}
#'  \item{sf_control}{The hyper-variability statistics for the control group}
#'  \item{sf_diff}{Difference between sf_treatment and sf_control: sf_treatment - sf_control}
#'  \item{sf_diff_pval}{P-values for testing whether the hyper-variability of each gene in the treatment group is larger than that in the control group}
#'  \item{sf_diff_fdr}{Adjusted p-values (FDR) of sf_diff_pval}
#'  \item{sf_diff_pval_alt}{P-values for testing whether the hyper-variability of each gene in the treatment group is smaller than that in the control group}
#'  \item{sf_diff_fdr_alt}{Adjusted p-values (FDR) of sf_diff_pval_alt}
#'  \item{sf_diff_pval_ts}{P-values for testing whether the hyper-variability of each gene in the treatment group is not equal to that in the control group}
#'  \item{sf_diff_fdr_ts}{Adjusted p-values (FDR) of sf_diff_pval_ts}
#' @keywords differential hyper-variability test
#' @examples 
#' \dontrun{
#' diff_disper <- scdv_main(treatment_data_adjust,treatment_data_weight,control_data_adjust,control_data_weight,num_permute=10000,span_param=0.5,ncore=6)
#' write.csv(cbind(match_gene_name,diff_disper),file="diff_hypervar.csv",row.names=FALSE)
#' }
#' @importFrom parallel mclapply
#' @importFrom parallel splitIndices
#' @export
scdv_main <- function(treatment_data,treatment_data_weight,control_data,control_data_weight,num_permute=1000,span_param=0.5,ncore=1){

  treatment_data_weight <- treatment_data_weight/rowSums(treatment_data_weight)
  control_data_weight <- control_data_weight/rowSums(control_data_weight)
  
	message('Estimating variance scale factor')
	flush.console()
	result <- scdv_estimate(treatment_data,treatment_data_weight,control_data,control_data_weight,span_param)

	message('Permutation process to obtain empirical p-value')
	flush.console()
	if(ncore > 1){
		permute_result <- scdv_permute_mc(treatment_data,treatment_data_weight,control_data,control_data_weight,result$var_expect_treatment,result$var_expect_control,num_permute,ncore)
	}
	else{
		permute_result <- scdv_permute(treatment_data,treatment_data_weight,control_data,control_data_weight,result$var_expect_treatment,result$var_expect_control,num_permute)
	}

	sf_diff_pval <- rep(NA,nrow(treatment_data))
	sf_diff_pval_alt <- rep(NA,nrow(treatment_data))
	sf_diff_pval_ts <- rep(NA,nrow(treatment_data))

	sf_diff <- result$scale_factor_treatment - result$scale_factor_control

	for(i in 1:nrow(treatment_data)){
		sf_diff_null <- permute_result$treatment_data_sf_per[i,] - permute_result$control_data_sf_per[i,]

		sf_diff_pval[i] <- length(which(sf_diff_null >= sf_diff[i]))/num_permute
		sf_diff_pval_alt[i] <- length(which(-sf_diff_null >= -sf_diff[i]))/num_permute
		sf_diff_pval_ts[i] <- length(which(abs(sf_diff_null) >= abs(sf_diff[i])))/num_permute
	}

	sf_diff_fdr <- p.adjust(sf_diff_pval,method="fdr")
	sf_diff_fdr_alt <- p.adjust(sf_diff_pval_alt,method="fdr")
	sf_diff_fdr_ts <- p.adjust(sf_diff_pval_ts,method="fdr")

	result_out <- data.frame(sf_treatment=result$scale_factor_treatment,sf_control=result$scale_factor_control,sf_diff=sf_diff,sf_diff_pval=sf_diff_pval,sf_diff_fdr=sf_diff_fdr,sf_diff_pval_alt=sf_diff_pval_alt,sf_diff_fdr_alt=sf_diff_fdr_alt,sf_diff_pval_ts=sf_diff_pval_ts,sf_diff_fdr_ts=sf_diff_fdr_ts)
	return(result_out)

}
