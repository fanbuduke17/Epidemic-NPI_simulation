# 04/25/2020
# staged simulation function
# adapted from "stochastic_coevolve_infer2"

library(Matrix)
library(igraph)
library(ggplot2)
library(dplyr)


stage_coevolve <- 
  function(N=50, tmax=100, 
           bet=0.05, gam=0.2, model = "SIR",
           stage_type = "time", stage_starts = c(0), quarantine = T,
           link_rates = list(list(alpha.r=rep(0.005,3), alpha.d=rep(0.05,3))),
           init.infec = 1, init.net = NULL, init.p = 0.1,
           verbose = F, plot = F){
    # 04/27/2020
    # Changes:
    # 1. add in "stages"; stage_type = "time" or "cases" (cumulative cases)
    # 2. link rates change across stages
    # 3. add plotting for "R_t", the dynamic reproduction number
    # 4. "quatantine=T" as default for convenience
    # 5. removed inference functionalities for simplicity
    
    
    #set.seed(seed)
    
    # # check edge rates validity
    # if(quarantine & (length(alpha.r) < 3 | length(alpha.d) < 3)){
    #   stop("Under quarantine, need to specify 3 values for edge connection/disconnection rates respectively!")
    # }
    
    # output basic info
    cat("N =", N, " Model:", model,"\n",
        "beta =", bet, " gamma =", gam, "\n",
        "staged by ", stage_type, "\n",
        "stage starting points:", paste(stage_starts,collapse=", "), "\n", 
        "init.infec =", init.infec, " init.p =", init.p, "\n")
    
    # summarization stats to be recorded
    time = NULL
    event.type = NULL
    preval = NULL
    dens = NULL
    ## 04/27/2020: add reproduction number
    Rt = NULL
    # add involved individual labels 
    per1 = NULL
    per2 = NULL
    
    
    #params = c(bet, gam, alpha.r, alpha.d)
    
    
    # initialize ER(p) graph if the initial netwok is not provided
    if(is.null(init.net)){
      init.net = sample_gnp(n = N, p = init.p, directed = F)
    }
    # convert to adjacency matrix
    adjmat = get.adjacency(init.net, type=c("both"), names=F)
    adjmat = as(adjmat,"dgTMatrix")
    # save the initial network structure (adj.mat)
    init.adj = adjmat
    
    
    ## check whether adjmat is symmetric and nnzero() returns an even number
    if(!isSymmetric(adjmat) | length(adjmat@i)%%2 == 1){
      stop(paste("The initial adjmat isn't symmetric, where nonzero =", 
                 nnzero(adjmat),"\n"))
    }
    
    # initialize epidemic
    infected = sample(N, init.infec)
    epid = rep(0,N); epid[infected] = 1
    cat("Initially infected: ",infected,"\n")
    # save initial cases
    init.infected = infected
    
    # initialize data objects to keep track of
    susceptible = which(epid==0)
    N.I = init.infec; N.S = N - N.I
    t.cur = 0
    if(quarantine){
      N.c = numeric(3); N.d = numeric(3)
      adjmat.ii = adjmat[infected,infected]
      N.c[3] = nnzero(adjmat.ii)/2
      N.d[3] = N.I * (N.I - 1)/2 - N.c[3]
      # both need this:
      adjmat.si = adjmat[susceptible,infected]
      if(model=="SIR"){
        recovered = NULL; N.R = 0
        adjmat.rs = adjmat[union(susceptible,recovered), union(susceptible,recovered)]
        N.c[1] = nnzero(adjmat.rs)/2
        N.d[1] = N.S * (N.S - 1)/2 - N.c[1]
        adjmat.ri = adjmat.si
        N.c[2] = nnzero(adjmat.ri)
        N.d[2] = N.S * N.I - N.c[2]
      }else{
        adjmat.ss = adjmat[susceptible,susceptible]
        N.c[1] = nnzero(adjmat.ss)/2
        N.d[1] = N.S * (N.S - 1)/2 - N.c[1]
        
        N.c[2] = nnzero(adjmat.si)
        N.d[2] = N.S * N.I - N.c[2]
      }
      # at the start: N.R = 0, so this works
      N.SI = N.c[2]
    }else{
      N.c = nnzero(adjmat)/2
      N.d = N * (N-1)/2 - N.c
      
      adjmat.si = adjmat[susceptible,infected]
      N.SI = nnzero(adjmat.si)
    }
    
    ## 04/27/2020: add in "stages"
    num_stage = length(stage_starts)
    stage.cur = 1
    
    alpha.r = link_rates[[1]]$alpha.r
    alpha.d = link_rates[[1]]$alpha.d
    
    cat("Stage ",stage.cur, " out of ", num_stage,":\n",
        "alpha.r =", paste(alpha.r,collapse = ","), 
        "alpha.d =", paste(alpha.d,collapse = ","),"\n\n")
    
    stage_times = NULL
    
    # iterations
    while (t.cur < tmax) {
      # NOTES #
      # a. check to make sure N.S also > 0
      # b. handle edge cases (N.S = 1 and/or N.I = 1)
      
      # # check whether all N's are non-negative
      # Ns = c(N.SI, N.I, N.d, N.c)
      # if(any(Ns < 0) | all(Ns == 0)){
      #   msg = paste("Weird stuff happened! All the Ns =", paste(Ns,collapse = ", "), "\n")
      #   stop(msg)
      # }
      
      
      ## 04/27/2020: add in "stages"
      if(num_stage > 0 & stage.cur < num_stage){
        
        if(stage_type == "time"){
          # check current time
          stage.now = max(which(stage_starts <= t.cur))
        }else{
          # check cumulative number of cases (all that's ever infected)
          num_cases = N-N.S
          stage.now = max(which(stage_starts <= num_cases))
        }
        
        # change current stage if...
        if(stage.now > stage.cur){
          alpha.r = link_rates[[stage.now]]$alpha.r
          alpha.d = link_rates[[stage.now]]$alpha.d
          stage.cur = stage.now
          
          cat("Stage ",stage.cur, " out of ", num_stage,":\n",
              "alpha.r =", paste(alpha.r,collapse = ","), 
              "alpha.d =", paste(alpha.d,collapse = ","),"\n\n")
          
          stage_times = c(stage_times, t.cur)
        }
      }
      
      
      # 1. calculate sum of risks and sample the next event time
      Lambda = bet * N.SI + N.I * gam + sum(alpha.r * N.d) + sum(alpha.d * N.c)
      t.next = t.cur + rexp(1, rate = Lambda)
      
      # 2. determine the event type
      ratios = c(bet * N.SI, N.I * gam, alpha.r * N.d, alpha.d * N.c)
      # 2.1 deal with network change
      if(quarantine){
        
        z = sample(8, 1, prob = ratios)
        
        if(z==3){
          # reconnect a random S-S/S-R/R-R pair
          if(model == "SIS"){
            num.dis = (N.S - 1) - rowSums(adjmat.ss)
            from.ind = sample(N.S,1,prob = num.dis); from = susceptible[from.ind]
            to.cands = which(adjmat.ss[from.ind,]==0)
          }else{
            num.dis = (N.S + N.R - 1) - rowSums(adjmat.rs)
            from.ind = sample(N.S + N.R, 1, prob = num.dis); from = union(susceptible, recovered)[from.ind]
            to.cands = which(adjmat.rs[from.ind,]==0)
          }
          to.cands = to.cands[to.cands!=from.ind]
          if(length(to.cands) == 1){
            to.ind = to.cands
          }else{
            to.ind = sample(to.cands,1)
          }
          if(model == "SIS"){
            to = susceptible[to.ind]
            adjmat.ss[as.integer(from.ind),as.integer(to.ind)] = 1
            adjmat.ss[as.integer(to.ind),as.integer(from.ind)] = 1
            msg = paste0("reconnect an S-S pair, (",from,",",to,")")
          }else{
            to = union(susceptible, recovered)[to.ind]
            adjmat.rs[as.integer(from.ind),as.integer(to.ind)] = 1
            adjmat.rs[as.integer(to.ind),as.integer(from.ind)] = 1
            msg = paste0("reconnect an S-S/S-R/R-R pair, (",from,",",to,")")
          }
          adjmat[as.integer(from),as.integer(to)] = 1
          adjmat[as.integer(to),as.integer(from)] = 1
          N.c[1] = N.c[1] + 1; N.d[1] = N.d[1] - 1
        }
        if(z==4){
          # reconnect a random S-I/R-I pair
          if(model == "SIS"){
            if (N.S == 1){
              from = susceptible
              to.ind = sample(which(adjmat.si==0),1); to = infected[to.ind]
            }else if (N.I == 1){
              num.dis = N.I - adjmat.si
              from.ind = sample(N.S,1,prob = num.dis); from = susceptible[from.ind]
              to = infected
            }else{
              num.dis = N.I - rowSums(adjmat.si)
              from.ind = sample(N.S,1,prob = num.dis); from = susceptible[from.ind]
              to.ind = sample(which(adjmat.si[from.ind,]==0),1); to = infected[to.ind]
            }
            msg = paste0("reconnect an S-I pair, (",from,",",to,").")
          }else{
            #N.SR = N.S + N.R; 
            # 03/27/2020: debug
            sus.recov = union(susceptible, recovered)
            N.SR = length(sus.recov)
            if (N.SR == 1){
              from = sus.recov
              # 03/27/2020: debug
              num.dis = N.SR - as.vector(adjmat.ri)
              to.ind = sample(N.I, 1, prob = num.dis); to = infected[to.ind]
              #to.ind = sample(which(adjmat.ri==0),1); to = infected[to.ind]
            }else if (N.I == 1){
              num.dis = N.I - as.vector(adjmat.ri)
              from.ind = sample(N.SR,1,prob = num.dis); from = sus.recov[from.ind]
              to = infected
            }else{
              num.dis = N.I - rowSums(adjmat.ri)
              # debugging...
              #cat(N.S, N.R, N.I, '\n')
              #cat(length(susceptible), length(recovered), length(infected),'\n')
              #print(dim(adjmat.ri))
              from.ind = sample(N.SR,1,prob = num.dis); from = sus.recov[from.ind]
              
              # 03/28/2020: debug
              vec.dis = 1 - as.vector(adjmat.ri[from.ind,])
              to.ind = sample(N.I,1,prob = vec.dis); to = infected[to.ind]
              #to.ind = sample(which(adjmat.ri[from.ind,]==0),1); to = infected[to.ind]
            }
            msg = paste0("reconnect an S-I/R-I pair, (",from,",",to,").")
          }
          adjmat[as.integer(from),as.integer(to)] = 1
          adjmat[as.integer(to),as.integer(from)] = 1
          # 03/27/2020
          # try to fix a bug
          if(length(susceptible)>0){
            adjmat.si = adjmat[susceptible,infected]
            N.SI = nnzero(adjmat.si)
          }else{
            N.SI = 0
          }
          
          if(model == "SIR"){ adjmat.ri = adjmat[sus.recov,infected] }
          
          N.c[2] = N.c[2] + 1; N.d[2] = N.d[2] - 1
          #N.SI = N.c[2]
        }
        if(z==5){
          # reconnect a random I-I pair
          num.dis = (N.I - 1) - rowSums(adjmat.ii)
          from.ind = sample(N.I,1,prob = num.dis); from = infected[from.ind]
          to.cands = which(adjmat.ii[from.ind,]==0)
          to.cands = to.cands[to.cands!=from.ind]
          if(length(to.cands) == 1){
            to.ind = to.cands
          }else{
            to.ind = sample(to.cands,1)
          }
          to = infected[to.ind]
          adjmat.ii[as.integer(from.ind),as.integer(to.ind)] = 1
          adjmat.ii[as.integer(to.ind),as.integer(from.ind)] = 1
          adjmat[as.integer(from),as.integer(to)] = 1
          adjmat[as.integer(to),as.integer(from)] = 1
          N.c[3] = N.c[3] + 1; N.d[3] = N.d[3] - 1
          
          msg = paste0("reconnect an I-I pair, (",from,",",to,").")
        }
        if(z==6){
          # disconnect a random S-S/R-S/R-R pair
          dis.ind = sample(N.c[1], 1) 
          if(model == "SIS"){
            from.ind = adjmat.ss@i[dis.ind] + 1; to.ind = adjmat.ss@j[dis.ind] + 1
            adjmat.ss[as.integer(from.ind),as.integer(to.ind)] = 0
            adjmat.ss[as.integer(to.ind),as.integer(from.ind)] = 0
            
            from = susceptible[from.ind]; to = susceptible[to.ind]
            
            msg = paste0("disconnect an S-S pair, (",from,",",to,").")
          }else{
            sus.recov = union(susceptible, recovered)
            from.ind = adjmat.rs@i[dis.ind] + 1; to.ind = adjmat.rs@j[dis.ind] + 1
            adjmat.rs[as.integer(from.ind),as.integer(to.ind)] = 0
            adjmat.rs[as.integer(to.ind),as.integer(from.ind)] = 0
            
            from = sus.recov[from.ind]; to = sus.recov[to.ind]
            
            msg = paste0("disconnect an S-S/S-R/R-R pair, (",from,",",to,").")
          }
          adjmat[as.integer(from),as.integer(to)] = 0
          adjmat[as.integer(to),as.integer(from)] = 0
          
          N.c[1] = N.c[1] - 1; N.d[1] = N.d[1] + 1
          
          # ## sometimes from/to is just empty... check it out
          # if(length(from)!=1){
          #   stop("from.ind = ", from.ind, 
          #        " but susceptible length is ", length(susceptible),
          #        " N.c[1] =", N.c[1], " dis.ind =", dis.ind, 
          #        " while adjmat.ss@i has length ", length(adjmat.ss@i))
          # }
          # ##
        }
        if(z==7){
          # disconnect a random S-I/R-I pair
          # dis.ind = sample(N.c[2], 1)
          if(model == "SIS"){
            if (N.S == 1){
              from = susceptible
              to.ind = sample(which(adjmat.si==1),1); to = infected[to.ind]
              adjmat[as.integer(from),as.integer(to)] = 0
              adjmat[as.integer(to),as.integer(from)] = 0
              adjmat.si = adjmat[susceptible,infected]
            }else if (N.I == 1){
              num.con = as.vector(adjmat.si)
              from.ind = sample(N.S,1,prob = num.con); from = susceptible[from.ind]
              to = infected
              adjmat[as.integer(from),as.integer(to)] = 0
              adjmat[as.integer(to),as.integer(from)] = 0
              adjmat.si = adjmat[susceptible,infected]
            }else{
              dis.ind = sample(N.c[2], 1)
              from = adjmat.si@i[dis.ind] + 1; to = adjmat.si@j[dis.ind] + 1
              adjmat.si[as.integer(from),as.integer(to)] = 0
              
              from = susceptible[from]; to = infected[to]
              adjmat[as.integer(from),as.integer(to)] = 0
              adjmat[as.integer(to),as.integer(from)] = 0
            }
            msg = paste0("disconnect an S-I pair, (",from,",",to,").")
          }else{
            N.SR = N.S + N.R; sus.recov = union(susceptible, recovered)
            if (N.SR == 1){
              from = sus.recov
              to.ind = sample(which(adjmat.ri==1),1); to = infected[to.ind]
              adjmat[as.integer(from),as.integer(to)] = 0
              adjmat[as.integer(to),as.integer(from)] = 0
              adjmat.ri = adjmat[sus.recov,infected]
            }else if (N.I == 1){
              num.con = adjmat.ri
              from.ind = sample(N.SR,1,prob = num.con); from = sus.recov[from.ind]
              to = infected
              adjmat[as.integer(from),as.integer(to)] = 0
              adjmat[as.integer(to),as.integer(from)] = 0
              adjmat.ri = adjmat[sus.recov,infected]
            }else{
              dis.ind = sample(N.c[2], 1)
              from = adjmat.ri@i[dis.ind] + 1; to = adjmat.ri@j[dis.ind] + 1
              # debugging...
              #cat('dis.ind=',dis.ind,'\n')
              #cat('from=',from,', to=',to, '\n')
              #cat(dim(adjmat.ri), '\n')
              #cat(length(adjmat.ri@i),  length(adjmat.ri@j), N.c[2], '\n')
              
              if(length(adjmat.ri@i) != N.c[2]){
                cat('Discrepancy when disconnecting H-I...\n')
                stop(paste0("At time ", t.next, ", ",msg,"\n"))
              }
              
              #adjmat.ri[as.integer(from),as.integer(to)] = 0
              
              from = sus.recov[from]; to = infected[to]
              adjmat[as.integer(from),as.integer(to)] = 0
              adjmat[as.integer(to),as.integer(from)] = 0
              adjmat.ri = adjmat[sus.recov,infected]
            }
            if(length(susceptible)>0){
              adjmat.si = adjmat[susceptible,infected]
            }else{
              adjmat.si = NULL
            }
            msg = paste0("disconnect an S-I/R-I pair, (",from,",",to,").")
          }
          
          N.c[2] = N.c[2] - 1; N.d[2] = N.d[2] + 1
          N.SI = nnzero(adjmat.si)
          
        }
        if(z==8){
          # disconnect a random I-I pair
          dis.ind = sample(N.c[3], 1) 
          from = adjmat.ii@i[dis.ind] + 1; to = adjmat.ii@j[dis.ind] + 1
          adjmat.ii[as.integer(from),as.integer(to)] = 0
          adjmat.ii[as.integer(to),as.integer(from)] = 0
          
          from = infected[from]; to = infected[to]
          adjmat[as.integer(from),as.integer(to)] = 0
          adjmat[as.integer(to),as.integer(from)] = 0
          
          N.c[3] = N.c[3] - 1; N.d[3] = N.d[3] + 1
          
          msg = paste0("disconnect an I-I pair, (",from,",",to,").")
        }
      }else{
        z = sample(4, 1, prob = ratios)
        if(z==3){
          # reconnect a random pair
          num.dis = (N - 1) - rowSums(adjmat)
          from = sample(N,1,prob = num.dis)
          to.cands = which(adjmat[from,]==0)
          to.cands = to.cands[to.cands!=from]
          if(length(to.cands) == 1){
            to = to.cands
          }else{
            to= sample(to.cands,1)
          }
          adjmat[as.integer(from), as.integer(to)] = 1
          adjmat[as.integer(to),as.integer(from)] = 1
          
          N.c = N.c + 1; N.d = N.d - 1
          
          # UPDATE: if any of S or I is empty now
          if(length(susceptible) == 0 | length(infected) == 0){
            adjmat.si = NULL; N.SI = 0
          }else{
            adjmat.si = adjmat[susceptible,infected]
            N.SI = nnzero(adjmat.si)
          }
          
          msg = paste0("reconnect a pair, (",from,",",to,").")
        }
        if(z==4){
          # disconnect a random pair
          dis.ind = sample(N.c, 1)
          from = adjmat@i[dis.ind] + 1; to = adjmat@j[dis.ind] + 1
          adjmat[from,to] = 0; adjmat[to,from] = 0
          N.c = N.c - 1; N.d = N.d + 1
          
          # UPDATE: if any of S or I is empty now
          if(length(susceptible)==0 | length(infected)==0){
            adjmat.si = NULL; N.SI = 0
          }else{
            adjmat.si = adjmat[susceptible,infected]
            N.SI = nnzero(adjmat.si)
          }
          
          msg = paste0("disconnect a pair, (",from,",",to,").")
        }
      }
      
      #2.2 deal with epidemic progress
      if(z==2){
        # recover an infected person
        rec.ind = sample(N.I,1)
        recover = infected[rec.ind]
        infected = infected[-rec.ind]
        N.I = N.I - 1 
        if(model == "SIS"){
          susceptible = c(susceptible,recover)
          epid[recover] = 0
          N.S = N.S + 1
        }else{
          epid[recover] = -1
          if(quarantine){
            recovered = c(recovered, recover)
            N.R = N.R + 1
          }
        }
        
        msg = paste0("individual ", recover,
                     " is recovered. Disease prevalence = ",
                     N.I/N, ".")
      }
      if(z==1){
        # select a susceptible person to infect
        if(N.S == 1){
          # only one person to infect
          new.infec = susceptible
          susceptible = NULL
        }else{
          # multiple susceptible inviduals to choose from
          if(N.I == 1){
            # only one infected person
            num.nei.i = adjmat.si
          }else{
            num.nei.i = rowSums(adjmat.si)
          }
          infec.ind = sample(N.S,1,prob = num.nei.i)
          new.infec = susceptible[infec.ind]
          susceptible = susceptible[-infec.ind]
        }
        epid[new.infec] = 1
        N.S = N.S - 1
        infected = c(infected, new.infec); N.I = N.I + 1
        
        msg = paste0("individual ", new.infec,
                     " is infected. Disease prevalence = ",
                     N.I/N, ".")
      }
      
      # A sanity check: if N.I==0, stop the simulation
      if(N.I==0){
        if(verbose){
          cat(paste0("At time ", t.next, ", "),msg,"\n")
        }
        # # still update inference statistics
        # del.t = t.next - t.cur
        # z = as.integer(z)
        # event.counts[z] = event.counts[z] + 1
        # tot.event = tot.event + 1
        # 
        # big.sums = big.sums + c(N.SI, N.I, N.d, N.c) * del.t
        
        # still have to record the event
        time = c(time, t.next)
        event.type = c(event.type, z)
        preval = c(preval, N.I)
        dens = c(dens, nnzero(adjmat))
        ## 04/27/2020: calculate Rt too
        Rt = c(Rt, 0)
        # here: a recovery must be the latest event
        per1 = c(per1, recover)
        per2 = c(per2, NA)
        
        cat("Disease extinct at time", t.next, ", simulation stops.\n")
        break
      }
      
      
      # # check whether adjmat is still symmetric--things have gone wrong somewhere
      # if(!isSymmetric(adjmat) | length(adjmat@i)%%2 == 1){
      #   stop(paste("The adjmat isn't symmetric any more, where nonzero =", 
      #              nnzero(adjmat), "and that's after z =", z,
      #              "from.ind =", from.ind, "to.ind = ", to.ind, 
      #              "to.cands =", paste(to.cands,collapse = ","),
      #              "from =", from, "to =", to,"\n"))
      # }
      
      
      # 2.2.* make updates about S-I, S-S, I-I connections if z==1 or 2
      # while handling edge cases of N.S <= 1 and/or N.I == 1
      if(z %in% c(1,2)){
        if(N.S == 0){
          adjmat.si = NULL
          N.SI = 0
          if(quarantine && model == "SIR" && N.R == 0){
            adjmat.ri = NULL
            N.c[2] = 0
          }
          # 03/27/2020: debug
          if(quarantine && model == "SIR" && N.R > 0){
            adjmat.ri = adjmat[recovered,infected]
            N.c[2] = nnzero(adjmat.ri)
          }
        }else{
          adjmat.si = adjmat[susceptible,infected]
          N.SI = nnzero(adjmat.si)
          if(quarantine && model == "SIR"){
            adjmat.ri = adjmat[union(susceptible,recovered),infected]
            N.c[2] = nnzero(adjmat.ri)
          }
        }
        if(quarantine){
          if(model == "SIS"){
            if(N.S <= 1){
              adjmat.ss = 0
              N.c[1] = 0
              N.d[1] = 0
            }else{
              adjmat.ss = adjmat[susceptible,susceptible]
              N.c[1] = nnzero(adjmat.ss)/2
              N.d[1] = N.S * (N.S - 1)/2 - N.c[1]
            }
            N.c[2] = N.SI
            N.d[2] = N.S * N.I - N.c[2]
          }else{
            #N.SR = N.S + N.R; 
            sus.recov = union(susceptible,recovered)
            # 03/27/2020: debug
            N.SR = length(sus.recov)
            
            if(N.SR <= 1){
              adjmat.rs = 0
              N.c[1] = 0
              N.d[1] = 0
            }else{
              adjmat.rs = adjmat[sus.recov,sus.recov]
              N.c[1] = nnzero(adjmat.rs)/2
              N.d[1] = N.SR * (N.SR - 1)/2 - N.c[1]
            }
            N.d[2] = N.SR * N.I - N.c[2]
          }
          if(N.I == 1){
            adjmat.ii = 0
            N.c[3] = 0
            N.d[3] = 0
          }else{
            adjmat.ii = adjmat[infected,infected]
            N.c[3] = nnzero(adjmat.ii)/2
            N.d[3] = N.I * (N.I - 1)/2 - N.c[3]
          }
        }
      }
      
      # # 3. update inference statistics and do inference occasionally
      # # 3.1 update stats
      # del.t = t.next - t.cur
      # z = as.integer(z)
      # event.counts[z] = event.counts[z] + 1
      # tot.event = tot.event + 1
      # 
      # big.sums = big.sums + c(N.SI, N.I, N.d, N.c) * del.t
      # 
      # # 3.2 inference if ...
      # if(tot.event %% infer.interval == 0){
      #   if(Bayes){
      #     # Bayesian inference: Gamma sampling
      #     a.post = a.pr + event.counts
      #     b.post = b.pr + big.sums
      #     cat("With", tot.event,"events, posterior means and variances:\n",
      #         a.post/b.post, "\n",
      #         a.post/(b.post^2), "\n")
      #     # record posterior stats
      #     if(return.infer){
      #       m.post = a.post/b.post
      #       lb.post = qgamma(.025, a.post, b.post)
      #       ub.post = qgamma(.975, a.post, b.post)
      #       this.chunk = cbind(m.post, lb.post, ub.post, event.counts, tot.event)
      #       Bayes.tab = rbind(Bayes.tab, this.chunk)
      #     }
      #     # plot
      #     if(infer.plot){
      #       par(mfrow=c(2,2))
      #       for(ix in 1:length(params)){
      #         v = vars[ix]; p = params[ix]
      #         sams = rgamma(samples, shape=a.post[ix], rate = b.post[ix])
      #         xl = range(sams, p)
      #         hist(sams, main=paste("Posterior samples for",vars[ix]),
      #              xlab = vars[ix], xlim=xl, col="lightblue")
      #         abline(v=p,col="red")
      #         if(demo.sleep & ix%%4 == 0){
      #           Sys.sleep(0.2)
      #         }
      #       }
      #     }
      #   }else{
      #     # MLE
      #     MLEs = event.counts/big.sums
      #     if(infer.verbose){
      #       cat("With",tot.event, "events, MLEs:","\n", MLEs, "\n")
      #     }
      #     MLE.tab = rbind(MLE.tab, c(tot.event, MLEs, event.counts))
      #   }
      # }
      
      # # updated 02/04/2020
      # # 3.3 examine network degree distribution if
      # if(net.deg.plot & (tot.event %% net.interval == 0)){
      #   degs = rowSums(adjmat)
      #   avg.deg = mean(degs)
      #   poi.degs = rpois(N, avg.deg)
      #   
      #   deg.dat = data.frame(Degrees = degs, DegPoi = poi.degs)
      #   print(
      #     ggplot(deg.dat) + geom_density(aes(x = Degrees, color="Actual degree")) +
      #       geom_density(aes(x = DegPoi, color="Poisson")) +
      #       labs(color="Distribution", 
      #            caption = paste("At t =", round(t.cur, digits = 2))) + 
      #       theme_bw(base_size = 14) %+replace%
      #       theme(legend.position = c(0.8,0.8))
      #   )
      # }
      
      
      
      # 4. report the event and summarize and set t.cur
      
      t.cur = t.next
      
      # record the event
      time = c(time, t.cur)
      event.type = c(event.type, z)
      preval = c(preval, N.I)
      dens = c(dens, nnzero(adjmat))
      ## 04/27/2020: calculate Rt too
      if(N.I == 0 | N.S == 0){
        Rt = c(Rt, 0)
      }else{
        # density of S-I links * number of S neighbors per I indiv.
        Rt = c(Rt, nnzero(adjmat.si)/N.I)
        # density of S-I links * N
        #Rt = c(Rt, nnzero(adjmat.si)/(N.I*N.S)*(N-1))
      }
      
      # record labels of individual(s) involved
      if (z >= 3){
        per1 = c(per1, from)
        per2 = c(per2, to)
      }else if (z==2){
        per1 = c(per1, recover)
        per2 = c(per2, NA)
      }else{
        per1 = c(per1, new.infec)
        per2 = c(per2, NA)
      }
      
      
      if(verbose){
        cat(paste0("At time ", t.cur, ", "),msg,"\n")
      }
      
    }
    
    # return results/summary
    cat("Simulation finished. At the end: \n", 
        "Disease prevalence =", N.I/N, "\n",
        "Network density = ", nnzero(adjmat)/(N*(N-1)),"\n")
    event.log = data.frame(time = time, event = event.type,
                           per1 = per1, per2 = per2,
                           preval = preval/N, dens = dens/(N*(N-1)),
                           Rt = Rt*bet/gam)
    
    # # inference at the end
    # if(Bayes){
    #   # Bayesian inference: Gamma sampling
    #   a.post = a.pr + event.counts
    #   b.post = b.pr + big.sums
    #   cat("Posterior means and variances with", tot.event, "events in total:\n",
    #       a.post/b.post, "\n",
    #       a.post/(b.post^2), "\n")
    #   cat("Event type counts:\n", event.counts,"\n")
    #   # record posterior stats
    #   if(return.infer){
    #     m.post = a.post/b.post
    #     lb.post = qgamma(.025, a.post, b.post)
    #     ub.post = qgamma(.975, a.post, b.post)
    #     this.chunk = cbind(m.post, lb.post, ub.post, event.counts, tot.event)
    #     Bayes.tab = rbind(Bayes.tab, this.chunk)
    #   }
    #   # plot
    #   if(infer.plot){
    #     par(mfrow=c(2,2))
    #     for(ix in 1:length(params)){
    #       v = vars[ix]; p = params[ix]
    #       sams = rgamma(samples, shape=a.post[ix], rate = b.post[ix])
    #       xl = range(sams, p)
    #       hist(sams, main=paste("Posterior samples for",vars[ix]),
    #            xlab = vars[ix], xlim=xl, col="lightblue")
    #       abline(v=p,col="red")
    #       if(demo.sleep & ix%%4 == 0){
    #         Sys.sleep(0.2)
    #       }
    #     }
    #   }
    # }else{
    #   # MLE
    #   MLEs = event.counts/big.sums
    #   cat("MLEs with", tot.event, "events in total:","\n", MLEs, "\n")
    #   cat("Event type counts:\n", event.counts,"\n")
    #   
    #   MLE.tab = rbind(MLE.tab, c(tot.event, MLEs, event.counts))
    #   MLE.tab = as.data.frame(MLE.tab)
    #   if(quarantine){
    #     names(MLE.tab) = c("event.num","beta","gamma",
    #                        "alpha.SS","alpha.SI","alpha.II",
    #                        "omega.SS","omega.SI","omega.II",
    #                        "infection","recovery",
    #                        "SS.connect","SI.connect","II.connect",
    #                        "SS.discon","SI.discon","II.discon")
    #   }else{
    #     names(MLE.tab) = c("event.num","beta","gamma","alpha","omega",
    #                        "infection","recovery","connect","discon")
    #   }
    # }
    
    if(plot){
      # subt = paste(model," beta =",bet," gamma =", gam, 
      #              " alpha.r =", alpha.r, " alpha.d =", alpha.d)
      subt = paste(model," beta =",bet," gamma =", gam, 
                   " stage_type:", stage_type, " stage points:", stage_starts)
      plot(preval ~ time, data = event.log, 
           xlab="Time", ylab="Disease prevalence", 
           main = "Disease Prevalence vs. Time", sub = subt,
           ylim = c(0,1), type="l",lwd=2)
      abline(v=stage_times, col="red", lwd=2)
      plot(dens ~ time, data = event.log,
           xlab="Time", ylab="Edge density", 
           main = "Network Edge Density vs. Time", sub = subt,
           type="l",lwd=2)
      abline(v=stage_times, col="red", lwd=2)
      plot(Rt ~ time, data = event.log,
           xlab="Time", ylab="R_t", 
           main = "Reproduction number vs. Time", sub = subt,
           type="l",lwd=2)
      abline(v=stage_times, col="red", lwd=2)
    }
    
    # if(infer.plot){
    #   #params = c(bet, gam, alpha.r, alpha.d)
    #   if(Bayes){
    #     par(mfrow=c(1,1))
    #   }else{
    #     # a function to calculate the frequentist 95% CI for MLEs
    #     MLE.CI <- function(x){
    #       l.hat = x[1]; n.obs = x[2]
    #       if (is.na(l.hat) || l.hat == 0){
    #         lb = 0; ub = 0
    #       }else if (n.obs >= 20){
    #         lb = l.hat * (1 + qnorm(.025)/sqrt(n.obs))
    #         ub = l.hat * (1 + qnorm(.975)/sqrt(n.obs))
    #       }else{
    #         lb = l.hat * qchisq(.025, 2*n.obs) / (2*n.obs)
    #         ub = l.hat * qchisq(.975, 2*n.obs) / (2*n.obs)
    #       }
    #       return(c(lb,ub))
    #     }
    #     
    #     lcol = length(names(MLE.tab)[-1])
    #     vars = names(MLE.tab)[-1][1:(lcol/2)]
    #     counts = names(MLE.tab)[-1][(lcol/2 + 1):lcol]
    #     e.num = MLE.tab$event.num
    #     if(quarantine){
    #       par(mfrow=c(2,2))
    #     }else{
    #       par(mfrow=c(2,2))
    #     }
    #     for(ix in 1:length(vars)){
    #       v = vars[ix]
    #       if(all(is.na(MLE.tab[[v]]))){
    #         plot.new()
    #       }else{
    #         tab.v = MLE.tab[,c(v,counts[ix])]
    #         bounds.v = t(apply(tab.v, 1, MLE.CI))
    #         bounds.v = as.data.frame(bounds.v)
    #         names(bounds.v) = c("lb","ub")
    #         #s.m = mean(MLE.tab[[v]], na.rm=T)
    #         #s.sd = sd(MLE.tab[[v]], na.rm=T)
    #         yl = range(min(bounds.v$lb), max(bounds.v$ub), params[ix])
    #         plot(MLE.tab[[v]]~e.num, xlab="# events", ylab=v,
    #              main = paste("MLE for", v, "v.s. # events"), 
    #              type="l", ylim=yl)
    #         lines(bounds.v$lb~e.num, lty=2, col="gray")
    #         lines(bounds.v$ub~e.num, lty=2, col="gray")
    #       }
    #       abline(h=params[ix], col="red")
    #     }
    #     par(mfrow=c(1,1))
    #   }
    # }
    # 
    # # add: print out big.sums if Bayesian
    # if(Bayes){
    #   cat("big.sums: \n", big.sums,"\n")
    # }
    # 
    # # 02/04/2020: degree distribution at the end
    # if(net.deg.plot){
    #   degs = rowSums(adjmat)
    #   avg.deg = mean(degs)
    #   poi.degs = rpois(N, avg.deg)
    #   
    #   deg.dat = data.frame(Degrees = degs, DegPoi = poi.degs)
    #   print(
    #     ggplot(deg.dat) + geom_density(aes(x = Degrees, color="Actual degree")) +
    #       geom_density(aes(x = DegPoi, color="Poisson")) +
    #       labs(color="Distribution", 
    #            caption = paste("At the end, t =", round(t.cur, digits = 2))) + 
    #       theme_bw(base_size = 14) %+replace%
    #       theme(legend.position = c(0.8,0.8))
    #   )
    # }
    
    
    # return event data
    # MODIFICATION: return true parametes too
    # if(return.infer){
    #   if(Bayes){
    #     Bayes.tab = as.data.frame(Bayes.tab)
    #     Bayes.tab$var = vars
    #     infer.tab = Bayes.tab
    #   }else{
    #     infer.tab = MLE.tab
    #   }
    #   return(list(G0 = init.adj, I0 = init.infected,
    #               events = event.log, infer=infer.tab,
    #               truth = params))
    # }else{
    #   return(list(G0 = init.adj, I0 = init.infected,
    #               events = event.log,truth = params))
    # }
    
    return(list(G0 = init.adj, I0 = init.infected, events = event.log,
                stage_starts = stage_starts, stage_type = stage_type, 
                stage_times = stage_times,
                params = list(beta = bet, gamma = gam, link_rates = link_rates)))
    
  }



# # try it out
# # 1 stage, by time
# res1 = stage_coevolve(N=100, bet = 0.3, gam = 0.12, plot = T)
# 
# # 2 stages, by time
# LR = list(list(alpha.r = rep(.005,3), alpha.d=rep(.05,3)),
#           list(alpha.r = c(.005,0,.005), alpha.d = c(0.05,.2,0.05)))
# 
# res2 = stage_coevolve(N=100, bet = 0.2, gam = 0.12, init.p = 0.05,
#                       stage_type = "time", stage_starts = c(0,3),
#                       link_rates = LR, plot = T)
# 
# # 2 stages, by cases
# res3 = stage_coevolve(N=100, bet = 0.2, gam = 0.12, init.p = 0.05,
#                       stage_type = "cases", stage_starts = c(0,20),
#                       link_rates = LR, plot = T)
# 
# # 3 stages, by time
# LR = list(list(alpha.r = rep(.005,3), alpha.d=rep(.05,3)),
#           list(alpha.r = c(.004,0,.004), alpha.d = c(0.05,.2,0.05)),
#           list(alpha.r = rep(.004,3), alpha.d=rep(.05,3)))
# 
# res4 = stage_coevolve(N=100, bet = 0.2, gam = 0.12, init.p = 0.05,
#                       stage_type = "time", stage_starts = c(0,5,20),
#                       link_rates = LR, plot = T)
# 
# res3 = stage_coevolve(N=100, bet = 0.2, gam = 0.12, init.p = 0.05,
#                       stage_type = "cases", stage_starts = c(0,20,80),
#                       link_rates = LR, plot = T)
