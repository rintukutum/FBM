args = commandArgs(trailingOnly=TRUE)

require(MCMCpack)
library(doParallel)
library(foreach)
library(cluster)
library(Rcpp)
library(RcppArmadillo)
library(RcppGSL)
library(scales)
library(coda)

Sys.setenv("PKG_CXXFLAGS"="-std=c++11")
sourceCpp("~/BI/BI.cpp")

localTest <- 0
singleTest <- 0
multipleReplicates <- 0
fullRun <- 0

if(args[7] == "local"){
    localTest <- 1
} else if (args[7] == "single"){
    singleTest <- 1
} else if (args[7] == "multiple"){
    multipleReplicates <- 1
} else if (args[7] == "full"){
    fullRun <- 1
}

Mode <- function(x) {
    ux <- unique(x)
    ux[which.max(tabulate(match(x, ux)))]
}

                                        #weiPaperIdx <- c(7,95, 264, 265, 327, 331, 351, 452, 458, 469, 511, 565, 588, 868, 907, 998)
weiPaperIdx <- c(6,92,259,265,266,329,333,353,402,455,462,475,516,571,594,869,907,998)

qcutAll <- c(0.05, 0.1, 0.15, 0.2, 0.25, 0.3)

nReplicates <-  as.numeric(args[12])


simulateData <- function(nSample, nGene, nMethy, nC, nCausalM, nCausalMbar, exchangeable=FALSE, MCAR, epsilon, epsilonGeneMbar, thetaGene, thetaMethy, seed, cv){
    set.seed(seed)
    
    load("~/BI/nasal/nasalProcessed.rdata")

    geneMTrue <- gene[cv,]
    gene <- gene[cv,]
    methy <- methy[cv,]
    Y <- Y[cv]
    C <- C[cv,]
    
    if(nMethy < nGene){
        stop("Not all methylation sites mapped to gene")
    }
    if(thetaGene+thetaMethy > 0.99){
        stop("Missing proportion greater than 99%.")
    }

    missGene <- rep(NA, nSample) # 1 means missing, note it means this sample missed entire gene exprs
    
    nuGene <- runif(nGene, -5, 5) #mean, exchangeable
    etaGene <- runif(nGene, 0.5,2) #sd, exchangeable
    
                                        #epsilonGeneMbar <- 1.2^epsilon #we generate geneMbar ~ N(0, epsilonGeneMbar) is sigmak
                                        #  epsilonGeneMbar <- epsilon
                                        #  nuMethy <- runif(nMethy, 0.7, 0.9)
                                        #  etaMethy <- runif(nMethy, 0.15,0.25)
                                        #nuMethy <- rep(0.8, nMethy) #We shift methy value to mean zero first
                                        #    etaMethy <- rep(0.2, nMethy)
    nuMethy <- rep(0, nMethy) #we assume all mean and var of methylation are same
    etaMethy <- rep(1, nMethy)

    nuC <- rep(0,nC)
    etaC <- rep(2, nC)

    
    if(nCausalM <0){
        print("No causal M specified")
        causalGeneMIdx <- sort(sample(1:nGene, round(nGene/10)))
        causalGeneMbarIdx <- sort(sample(1:nGene, round(nGene/10)))
    }else{
                                        #print(paste(nGene, nCausalM, "M"))
                                        #print(paste(nGene, nCausalMbar, "Mbar"))
        causalGeneMIdx <- sort(sample(1:nGene, nCausalM))
        causalGeneMbarIdx <- sort(sample(1:nGene, nCausalMbar))
    }
    
    omegaTrue <- rep(5, nGene) #for any methylation towards gene
    
    gammaTrue <- c(0, 10, 10, 10) # beta0, betaGeneM, betaGeneMbar, betaC(any clinical)
                                        #  gammaTrue <- c(0, 2, 2/(epsilon), 2)

    effectiveMethy <- rep(0, nMethy) #Adding sparsity, 0 means sparse, 1 means methy is effetive on gene.
    for (k in 1:nGene){
        effectiveMethy[which(mapMethy==k)][1]=1 #make sure at least one methy is effective per gene.
    }
                                        #    effectiveMethy[which(effectiveMethy==0)] <- rbinom(nMethy-nGene, 1, 1) #0% sparsity on the rest of the methy.
    effectiveMethy <- rep(1, nMethy) # We use all methy    
    

    if(nSample < 2){
        stop("More than 1 sample is needed")
    }
    if(MCAR==TRUE){
        obsGeneIdx <- 0
        while(length(obsGeneIdx) <2){
            missGene <- rbinom(nSample, 1, thetaGene)
            missGeneIdx <- which(missGene==1)
            obsGeneIdx <- setdiff(1:nSample, missGeneIdx)
        }        
        missMethy <- rep(0,nSample)
        missMethy[obsGeneIdx] <- rbinom(length(obsGeneIdx), 1, thetaMethy/(1-thetaGene))
    } else {# phenotype is a reasonable variable associated with missingness
        psiTrue <- c(NA, NA)
        psiTrue[2] <- 1/mean(Y)
        psiTrue[1] <- qnorm(thetaGene) - 1
        missGene <- rbinom(nSample, 1, pnorm(psiTrue[1] + psiTrue[2]*Y))
        missGeneIdx <- which(missGene==1)
        obsGeneIdx <- setdiff(1:nSample, missGeneIdx)

        psiTrue[1] <- qnorm(thetaMethy) - 1
        missMethy <- rep(0,nSample)
        missMethy[obsGeneIdx] <- rbinom(length(obsGeneIdx), 1,  min(1,pnorm(psiTrue[1] + psiTrue[2]*Y)/(1-thetaGene)))
    }
    missMethyIdx <- which(missMethy==1)
    obsMethyIdx <- setdiff(1:nSample, missMethyIdx)

    if( length(obsMethyIdx) <2){
        stop("More than 1 sample is needed")
    }
    geneObs <- as.matrix(gene[obsGeneIdx,])
    methyObs <- as.matrix(methy[obsMethyIdx,])
    ## colnames(methy) <- paste("methy", seq(1:nMethy), ".",seq(1:nMethy), ".gene", mapMethy, ".",seq(1:nMethy) , sep="" )
    ## rownames(methy) <- paste("sample",seq(1:nSample),sep="")
    ## colnames(geneObs) <- paste("gene",1:nGene, sep="")
    ## rownames(geneObs) <- paste("sample",obsGeneIdx,sep="")

    ## colnames(C) <- paste("clinical",1:nC, sep="")
    ## rownames(C) <- paste("sample",seq(1:nSample),sep="")
    
    if(is.null(colnames(methy))){
        colnames(methy) <- paste("methy", seq(1:nMethy), ".",seq(1:nMethy), ".gene", mapMethy, ".",seq(1:nMethy) , sep="" )
    }
    if(is.null(rownames(methy))){
        rownames(methy) <- paste("sample",seq(1:nSample),sep="")
    }
    if(is.null(colnames(geneObs))){
        colnames(geneObs) <- paste("gene",1:nGene, sep="")
    }
    if(is.null(rownames(geneObs))){
        rownames(geneObs) <- paste("sample",obsGeneIdx,sep="")
    }
    if(is.null(colnames(C))){
        colnames(C) <- paste("clinical",1:nC, sep="")
    }
    if(is.null(rownames(C))){
        rownames(C) <- paste("sample",seq(1:nSample),sep="")
    }
    
                                        #write.csv(methy, paste(wd, "/methyData.csv", sep=""), row.names=F,quote=F )
                                        #write.csv(geneObs, paste(wd, "/geneData.csv",sep=""),row.names=F, quote=F )
                                        #write.csv(C, paste(wd, "/clinicalData.csv", sep=""), row.names=F, quote=F )
    write.csv(methy, paste(wd, "/methyData.csv", sep=""), quote=F ) # in future write out methyObs
    write.csv(geneObs, paste(wd, "/geneData.csv",sep=""), quote=F )
    write.csv(C, paste(wd, "/clinicalData.csv", sep=""), quote=F )
    print(paste("Done simulating data, nSample:", nSample, " nMissGene:",length(missGeneIdx), " nMissMethy:", length(missMethyIdx)))
    
    return(list(Y=Y, geneObs=geneObs, methyObs=methyObs, mapMethy=mapMethy, C=C, missGeneIdx=missGeneIdx, obsGeneIdx=obsGeneIdx, missMethyIdx=missMethyIdx, obsMethyIdx=obsMethyIdx, causalGeneMIdx=causalGeneMIdx, causalGeneMbarIdx=causalGeneMbarIdx, geneTrue=gene, geneMTrue=geneMTrue, methyTrue=methy, gammaTrue=gammaTrue, omegaTrue=omegaTrue, effectiveMethy=effectiveMethy))

}

#######################################################
### Bayesian Imputation (BI) with gene/methy missing ##
#######################################################
                                        #now using Rcpp
plotting <- function(data, result, wd){
    opar <- par()
    
    pdf(paste(wd, "/convergence.pdf",sep=""))
    par(mfrow=c(3,2))
    
    for (k in 1:(min(nGene,50))){
        for(j in which(data$mapMethy==k)){
            plot(result$omega[1:nItr,j],type="l", ylab=paste("omega",j,k),xlab="Iterations")
            abline(h=data$omegaTrue[1]*data$effectiveMethy[j], col=3)
        }
    }

    for (k in c(1:(min(nGene,30)),data$causalGeneMIdx,weiPaperIdx) ){
        plot(result$gammaM[1:nItr,k],type="l", ylab=paste("gammaM",k),xlab="Iterations")
        if(k %in% data$causalGeneMIdx ){
            abline(h=data$gammaTrue[2], col=3)  
        }else{
            abline(h=0, col=3)  
        }
    }
    
    for (k in  c(1:(min(nGene,30)),data$causalGeneMbarIdx,weiPaperIdx) ){
        plot(result$gammaMbar[1:nItr,k],type="l", ylab=paste("gammaMbar",k),xlab="Iterations")
        if(k %in% data$causalGeneMbarIdx ){
            abline(h=data$gammaTrue[3], col=3)  
        }else{
            abline(h=0, col=3)  
        }
    }
    if(nC!=0){
        for (k in 1:nC){
            plot(result$gammaC[1:nItr,k],type="l", ylab=paste("gammaC",k),xlab="Iterations")
            abline(h=data$gammaTrue[4], col=3)  
        }
    }
    
    plot(result$sigma[1:nItr],type="l", ylab="sigma",xlab="Iterations")
    abline(h=epsilon, col=3)
    
    for (k in 1:(min(nGene,30))){
        plot(result$sigmak[1:nItr,k],type="l", ylab=paste("sigmak",k),xlab="Iterations")
    }
    
    plot(result$tauM[1:nItr],type="l", ylab=paste("tauM",k),xlab="Iterations")
    abline(h=1, col=3)
    
    plot(result$tauMbar[1:nItr],type="l", ylab=paste("tauMbar",k),xlab="Iterations")
    abline(h=1, col=3)

    for (j in 1:(min(nMethy,30))){
        plot(result$IOmega[1:nItr,j],type="l", ylab=paste("IOmega ",j,xlab="Iterations"))
        abline(h=1, col=3)
    }

    for (k in  c(1:(min(nGene,30)),data$causalGeneMIdx,weiPaperIdx) ){

        plot(result$IM[1:nItr,k],type="l", ylab=paste("IM ",k,xlab="Iterations"))
        if(k %in% data$causalGeneMIdx){
            abline(h=1, col=3)
        }else{
            abline(h=0, col=3)
        }
    }
    for (k in  c(1:(min(nGene,30)),data$causalGeneMbarIdx,weiPaperIdx) ){
        plot(result$IMbar[1:nItr,k],type="l", ylab=paste("IMbar ",k,xlab="Iterations"))
        if(k %in% data$causalGeneMbarIdx){
            abline(h=1, col=3)
        }else{
            abline(h=0, col=3)
        }
    }
    plot(result$piM[1:nItr],type="l", ylab=paste("piM ",k,xlab="Iterations"))
    plot(result$piMbar[1:nItr],type="l", ylab=paste("piMbar ",k,xlab="Iterations"))
    dev.off()
}

BFDR <- function(Ipm, n, nGene){ #Ipm is the feature selection posterior mean.
    BFDRtmp <- matrix(NA,nGene,2) #t, BFDR(t)
    PMtmp <- rep(NA, nGene)
    qtmp <- rep(NA, nGene)
    PMtmp <- 1-Ipm 
    sortedPM <- sort(PMtmp)
    for(k in 1:nGene){
        BFDRtmp[k,1] <- sortedPM[k]
        BFDRtmp[k,2] <- sum(sortedPM[1:k])/k
    }
    for(k in 1:nGene){
        qtmp[k] <- min( BFDRtmp[ which(BFDRtmp[,1] > PMtmp[k]), 2],1 )
    }

    return(list(q=qtmp))
}

estimating <- function(data, result,wd, testData){
    nItrActual <- result$nItrActual
    nBurninActual <- result$nBurninActual
                                        #  nBurninActual <- round(nItr/3)
    nGene <- dim(data$geneObs)[2]    
    nC <- dim(data$C)[2]
    gammaMTrue <- rep(0, nGene)
    gammaMTrue[data$causalGeneMIdx] <- data$gammaTrue[2]
    gammaMbarTrue <- rep(0, nGene)
    gammaMbarTrue[data$causalGeneMbarIdx] <- data$gammaTrue[3]
    gammaCTrue <- rep(data$gammaTrue[4], nC)
    
    IMEst <- rep(0,nGene)
    IMbarEst <- rep(0,nGene)
    IEst <- rep(0, nGene) # OR logic of IM and IMbar
    IPatternEst <- rep(0, nGene) #1 is 01, 2 is 10, 3 is 11
    gammaMEst <- rep(0,nGene)
    gammaMbarEst <- rep(0,nGene)
    gammaMSd <- rep(0,nGene)
    gammaMbarSd <- rep(0,nGene)
    gammaCEst <- rep(0,nC)
    gammaCSd <- rep(0,nC) 
    
    for(k in 1:nGene){

      if(pnorm(abs(geweke.diag(as.numeric(result$gammaM[1:nItrActual,k]))$z),lower.tail=FALSE)*2 <0.05)
        print(paste("Warning: convergence not achieved by Geweke's diagnostics. Gene M", k))

              tmpData <- as.numeric(result$gammaM[nBurninActual:nItrActual,k])
        gammaMEst[k] <- signif(median(tmpData),4)
        gammaMSd[k] <- signif(sd(tmpData),4)
        IMEst[k] <- mean(result$IM[nBurninActual:nItrActual,k])
        
        if(pnorm(abs(geweke.diag(as.numeric(result$gammaMbar[1:nItrActual,k]))$z),lower.tail=FALSE)*2 <0.05)
          print(paste("Warning: convergence not achieved by Geweke's diagnostics. Gene Mbar", k))
        
        tmpData <- as.numeric(result$gammaMbar[nBurninActual:nItrActual,k])
        gammaMbarEst[k] <- signif(median(tmpData),4)
        gammaMbarSd[k] <- signif(sd(tmpData),4)
        IMbarEst[k] <- mean(result$IMbar[nBurninActual:nItrActual,k])

        tmp <- result$IM[nBurninActual:nItrActual,k] + 2*result$IMbar[nBurninActual:nItrActual,k]
        patternTmp <- Mode(tmp[which(tmp!=0)])
        if(is.na(patternTmp)){
            IPatternEst[k] <- 0
        } else{
            IPatternEst[k] <- patternTmp
        }
        tmp[which(tmp>1)] <- 1
        IEst[k] <- mean(tmp)
    }
    
    for(k in 1:nC){
        tmpData <- as.numeric(result$gammaC[nBurninActual:nItrActual,k])
        gammaCEst[k] <- signif(median(tmpData),4)
        gammaCSd[k] <- signif(sd(tmpData),4)
    }
    
    
    table <- matrix(NA, 1+2*nGene+nC, 6)
    table[1,] <- c("\ ","geneName","Estimate", "Truth", "Selected","q")
    table[2:(1+2*nGene+nC),1] <- rep("\ ", 2*nGene+nC )
                                        #\multirow{2}{*}{\begin{sideways} 2X~ \end{sideways}} & MI &0.5&1.32&-1.82&0.969&0.00829\\
                                        #&Consensus&0.5&1.72&-2.3&1&0.0203\\
    table[2:(1+2*nGene+nC),2] <- c(colnames(data$geneObs),colnames(data$geneObs), colnames(data$C))
    table[2:(1+2*nGene+nC),3] <- c(gammaMEst, gammaMbarEst, gammaCEst)
    table[2:(1+2*nGene+nC),4] <- c(gammaMTrue, gammaMbarTrue, gammaCTrue)
    table[2:(1+2*nGene+nC),5] <- c(IMEst, IMbarEst, rep("\ ", nC))

    qM <- BFDR(IMEst, dim(data$geneObs)[1], dim(data$geneObs)[2] )$q
    qMbar <- BFDR(IMbarEst, dim(data$geneObs)[1], dim(data$geneObs)[2] )$q
    q <- BFDR(IEst, dim(data$geneObs)[1], dim(data$geneObs)[2] )$q

    table[2:(1+2*nGene+nC),6] <- c(qM, qMbar, rep("\ ", nC))

                                        #we have only nMethy meaningful omega
                                        # without loss of generalizability, we only use the first omega
    sigmaEst <- signif(median(result$sigma[nBurninActual:nItrActual]),4)
    tauMEst <- signif(median(result$tauM[nBurninActual:nItrActual]),4)
    tauMbarEst <- signif(median(result$tauMbar[nBurninActual:nItrActual]),4)
    sigmakEst <- signif(apply(result$sigmak[nBurninActual:nItrActual,],2,median),4)

    omegaEst <- signif(apply(result$omega[nBurninActual:nItrActual,],2,median),4)

    geneM <- testData$geneTrue
    
    for(i in 1:nGene){
        tmpIdx <-  which(testData$mapMethy==i)
        if(length(tmpIdx)==1)
            geneM[,i] <- sum(testData$methyTrue[, tmpIdx] * omegaEst[tmpIdx])
        else
            geneM[,i] <- testData$methyTrue[, tmpIdx] %*% omegaEst[tmpIdx]
    }

    geneMbar <- testData$geneTrue - geneM

    MSEyHatEst <- rep(0, length(qcutAll))
    
    for( i in 1:length(qcutAll)){       
        tmpCausalIdxM <- which(qM < qcutAll[i])
        tmpCausalIdxMbar <- which(qMbar < qcutAll[i])
        if(length(tmpCausalIdxM)==1){
            yHatEstTmp <- geneM[,tmpCausalIdxM] %*% t(gammaMEst[tmpCausalIdxM]) + geneMbar[,tmpCausalIdxMbar] %*% gammaMbarEst[tmpCausalIdxMbar] + testData$C %*% gammaCEst
        } else if(length(tmpCausalIdxMbar)==1){
            yHatEstTmp <- geneM[,tmpCausalIdxM] %*% gammaMEst[tmpCausalIdxM] + geneMbar[,tmpCausalIdxMbar] %*% t(gammaMbarEst[tmpCausalIdxMbar]) + testData$C %*% gammaCEst
        } else{
            yHatEstTmp <- geneM[,tmpCausalIdxM] %*% gammaMEst[tmpCausalIdxM] + geneMbar[,tmpCausalIdxMbar] %*% gammaMbarEst[tmpCausalIdxMbar] + testData$C %*% gammaCEst
        }
                                        #    yHatEstTmp <- as.matrix(testData$geneMTrue)%*%gammaMEst + as.matrix(testData$geneTrue-testData$geneMTrue)%*%gammaMbarEst + as.matrix(testData$C)%*%gammaCEst
        
        MSEyHat <- yHatEstTmp-testData$Y
                                        #  dftmp <- ( length(testData$Y) - nCausalM - nCausalMbar - nC)
        dftmp <- max( ( length(testData$Y) - length(tmpCausalIdxM) - length(tmpCausalIdxMbar) - nC), round(length(testData$Y)/2) )
        
        MSEyHatEst[i] <- sum(MSEyHat^2)/ dftmp
    }
    
    omegaMeanEst <- median(omegaEst)
    omegaSd <- sd(omegaEst)
    
    write.table(table, paste(wd, "/estimates",sep=""),
                sep="&", quote=F, col.names=F, row.names=F, eol="\\\\\n")
    
    cat("mean(omega)\n",file=paste(wd, "/estimatesAll", sep=""),append=T)
    cat(omegaMeanEst, file=paste(wd, "/estimatesAll", sep=""),append=T, sep=",")
    cat("\nsigmaEst,tauMEst,tauMbarEst\n",file=paste(wd, "/estimatesAll", sep=""),append=T)
    cat(c(sigmaEst,tauMEst,tauMbarEst),file=paste(wd, "/estimatesAll", sep=""),append=T, sep=",")
    cat("\nsigmakEst\n",file=paste(wd, "/estimatesAll", sep=""),append=T)
    cat(sigmakEst, file=paste(wd, "/estimatesAll", sep=""),append=T, sep=",")
    
    return(list(gammaMEst=gammaMEst, gammaMbarEst=gammaMbarEst, gammaCEst=gammaCEst, omegaEst=omegaEst,omegaMeanEst=omegaMeanEst, IMEst=IMEst,IMbarEst=IMbarEst, sigmaEst=sigmaEst, tauMEst=tauMEst, tauMbarEst=tauMbarEst, sigmakEst=sigmakEst, MSEyHatEst = MSEyHatEst, gammaMSd=gammaMSd, gammaMbarSd=gammaMbarSd, gammaCSd=gammaCSd, omegaSd=omegaSd, qM=qM, qMbar=qMbar,q=q, IEst=IEst, IPatternEst=IPatternEst))
}








nGene <- as.numeric(args[8])
nCausalM <-  as.numeric(args[9])
nCausalMbar <- as.numeric(args[10])
nMethy <-  as.numeric(args[11])

nGene<-1000
nMethy <- 2619
                                        #nCausalGene <- 10 #fix
nCausalM <- 10 #fix
nCausalMbar <- 10 #fix

nC <- 2
exchangeable <- FALSE
MCAR <- TRUE

if( fullRun | multipleReplicates ){
    wd <- args[1]
    setwd(wd)

    noCFlag <- 0 #flag for no clinical variable input
    nCtmp <- nC
    if(nC==0){
        noCFlag=1
        nCtmp <- 1
    }
    nItr <- as.numeric(args[4])
    seed <- as.numeric(args[3])
    thetaGene <- as.numeric(args[5])
    thetaMethy <- as.numeric(args[6])

                                        #    cl <- makeCluster(as.numeric(args[2]))
                                        #    registerDoParallel(cl)

                                        #    all_n <- c(20,30,50,100,200,500)
    nSample <- 460
    n=1
    if(args[13] == "strong"){
        epsilon <- 0.01
    } else if( args[13]=="mid"){
        epsilon <- 0.5
    } else if( args[13]=="weak"){
        epsilon <- 2
    }else if( args[13]=="midstrong"){
        epsilon <- 0.1
    }else if( args[13]=="superweak"){
        epsilon <- 3
    }else if( args[13]=="ultraweak"){
        epsilon <- 5
    }

    epsilonGeneMbar <- 2

    parNames <- c( expression(paste(gamma^M," causal")),  expression(paste(gamma^bar(M), " causal")),  expression(paste(gamma^M, " non-causal")),  expression(paste(gamma^bar(M), " non-causal")),  expression(gamma^C),  expression(omega), expression(hat(Y)))
    nPar <- length(parNames) #  gammaM_causal, gammaMbar_causal,gammaM_nc, gammaMbar_nc, gammaC, omegaMean, yHat

    sensSpecNames <- c( expression(paste(I^M,"sens")),  expression(paste(I^M,"spec")),  expression(paste(I^bar(M),"sens")),expression(paste(I^bar(M),"spec")), expression("Overall sens"),  expression("Overall spec"))

    methods <- c("CC", "BI", "Full")
    
    r <- as.numeric(args[14])

                                        #    colors <- c(colors()[461],  colors()[282], colors()[555], colors()[610])
    colors<- c(colors()[26],  colors()[261], colors()[35], colors()[614],  colors()[621]) #blue, grey, red, green, yellow.
    
    bi <- list()
    biCC<- list()
    biFull <- list()
    biGene <- list()
    est <- list()
    estCC <- list()
    estFull <- list()
    estGene <- list()
    data <- list()
    dataCC <- list()
    dataFull <- list()
    dataGene <- list()
    testData <- list() # same test data for BI, CC and FUll
                                        # ROC, Youden, FDR, and TP

    bicv <- list()
    bicvCC<- list()
    bicvGene <- list()
    estcv <- list()
    estcvCC <- list()
    estcvGene <- list()
    datacv <- list()
    datacvCC <- list()
    datacvGene <- list()
    testDatacv <- list()
    
    folds <- cut(seq(1,nSample),breaks=10,labels=FALSE)

    if(r==0){
        load("~/BI/nasal/nasalProcessed.rdata")
        dataSilver <- simulateData(nSample, nGene, nMethy,nC, nCausalM, nCausalMbar, exchangeable, MCAR, epsilon,epsilonGeneMbar, 0, 0, seed+r, 1:nSample)
        
        set.seed(seed)
        biSilver <- BIcpp(dataSilver, nItr, seed, "Full")

        estSilver <- estimating(dataSilver, biSilver, wd, dataSilver)

        tableM <- matrix(NA, nGene+length(weiPaperIdx),3)
        tableMbar <- tableM
        tableM <- cbind( colnames(gene)[order(estSilver$qM)], estSilver$gammaMEst[order(estSilver$qM)],  estSilver$qM[order(estSilver$qM)])
        tableMbar <- cbind( colnames(gene)[c(weiPaperIdx,order(estSilver$qMbar))], estSilver$gammaMbarEst[c(weiPaperIdx,order(estSilver$qMbar))],  estSilver$qMbar[c(weiPaperIdx,order(estSilver$qMbar))] )
        table <- cbind( colnames(gene)[order(estSilver$q)], estSilver$q[order(estSilver$q)], estSilver$IPatternEst[order(estSilver$q)])

        write.table(tableM, paste(wd, "/estSilverM",sep=""), sep=" & ", quote=F, col.names=F, row.names=F )
        write.table(tableMbar, paste(wd, "/estSilverMbar",sep=""), sep=" & ", quote=F, col.names=F, row.names=F)
        write.table(table, paste(wd, "/estSilver",sep=""), sep=" & ", quote=F, col.names=F, row.names=F)
        
                                        #        dataSilver$causalGeneMIdx <- order(estSilver$qM)[1:10]
                                        #        dataSilver$causalGeneMbarIdx <- order(estSilver$qMbar)[1:10]

        qcut <- as.numeric(args[15])

        dataSilver$causalGeneMIdx <- which(estSilver$qM < 0.05) #fix, or 0.05
        dataSilver$causalGeneMbarIdx <- which(estSilver$qMbar < 0.05)
        
        save(dataSilver, estSilver, biSilver, file=paste(wd, "/dataSilver.rdata",sep=""))
    }else{
        load(paste(wd, "/dataSilver.rdata",sep=""))

        nCausalM <- min(round(nGene/2), length(dataSilver$causalGeneMIdx))
        nCausalMbar <-  min(round(nGene/2), length(dataSilver$causalGeneMbarIdx))
                                        #print(paste(nCausalM, nCausalMbar))
        
        cvFoldTest <- which(folds==1)
        cvFold <- (1:nSample)[- cvFoldTest]
                                        #print(paste(length(cvFoldTest), "+", length(cvFold)))
        
        data[[r]] <- simulateData(length(cvFold), nGene, nMethy,nC, nCausalM, nCausalMbar, exchangeable, MCAR, epsilon,epsilonGeneMbar, thetaGene, thetaMethy, seed+r, cvFold)
        data[[r]]$causalGeneMIdx <- dataSilver$causalGeneMIdx
        data[[r]]$causalGeneMbarIdx <- dataSilver$causalGeneMbarIdx

                                        #testData[[r]] <- dataSilver
        testData[[r]] <- simulateData(length(cvFoldTest), nGene, nMethy,nC, nCausalM, nCausalMbar, exchangeable, MCAR, epsilon,epsilonGeneMbar, 0, 0, seed+r, cvFoldTest)

        dataCC[[r]] <- data[[r]]
        dataCC[[r]]$missGeneIdx <- integer(0)
        dataCC[[r]]$missMethyIdx <- integer(0)
        missJointIdx <- sort(c( data[[r]]$missGeneIdx, data[[r]]$missMethyIdx))
        obsJointIdx <- setdiff(1:length(cvFold), missJointIdx)
        dataCC[[r]]$obsMethyIdx <- 1:length(obsJointIdx)            
        dataCC[[r]]$obsGeneIdx <- 1:length(obsJointIdx)
        dataCC[[r]]$Y <- dataCC[[r]]$Y[obsJointIdx]
        dataCC[[r]]$methyObs <- as.matrix(dataCC[[r]]$methyTrue[obsJointIdx,])
        dataCC[[r]]$geneObs <- as.matrix(dataCC[[r]]$geneTrue[obsJointIdx,])
        dataCC[[r]]$C <- as.matrix(dataCC[[r]]$C[obsJointIdx,])
        dataCC[[r]]$geneMTrue <- as.matrix(dataCC[[r]]$geneMTrue[obsJointIdx,])
        dataCC[[r]]$geneTrue <- as.matrix(dataCC[[r]]$geneTrue[obsJointIdx,])

        dataGene[[r]] <- dataCC[[r]]
        dataGene[[r]]$Y <- c(dataCC[[r]]$Y, data[[r]]$Y[data[[r]]$missGeneIdx])
        dataGene[[r]]$methyObs <- rbind(dataCC[[r]]$methyObs, data[[r]]$methyTrue[data[[r]]$missGeneIdx,])
        dataGene[[r]]$C <- rbind(as.matrix(dataCC[[r]]$C), as.matrix(data[[r]]$C[data[[r]]$missGeneIdx,]))
        dataGene[[r]]$geneMTrue <- rbind(dataCC[[r]]$geneMTrue, data[[r]]$geneMTrue[data[[r]]$missGeneIdx,])
        dataGene[[r]]$geneTrue <- rbind(dataCC[[r]]$geneTrue, data[[r]]$geneTrue[data[[r]]$missGeneIdx,])

        dataGene[[r]]$missMethyIdx <- integer(0)
        dataGene[[r]]$obsMethyIdx <- 1:length(dataGene[[r]]$Y)
        dataGene[[r]]$missGeneIdx <- (length(obsJointIdx)+1):length(dataGene[[r]]$Y)
        dataGene[[r]]$obsGeneIdx <- 1:(length(obsJointIdx))
        
        ## dataFull[[r]] <- data[[r]]
        ## dataFull[[r]]$missGeneIdx <- integer(0)
        ## dataFull[[r]]$missMethyIdx <- integer(0)
        ## dataFull[[r]]$obsMethyIdx <- 1:length(data[[r]]$Y)
        ## dataFull[[r]]$obsGeneIdx <- 1:length(data[[r]]$Y)
        ## dataFull[[r]]$methyObs <- as.matrix(data[[r]]$methyTrue)
        ## dataFull[[r]]$geneObs <- as.matrix(data[[r]]$geneTrue)
        ## dataFull[[r]]$geneMTrue <- as.matrix(data[[r]]$geneMTrue)
        ## dataFull[[r]]$geneTrue <- as.matrix(data[[r]]$geneTrue)
        
        load("~/BI/nasal/nasalProcessed.rdata")

        ##                                 #Full
        ## set.seed(seed)
        ## biFull[[r]] <- BIcpp(dataFull[[r]], nItr, seed, "Full")
        ## wdSub <- paste(wd,"/n",n,"_r",r,"_Full",sep="")
        ## dir.create(wdSub)
        ## estFull[[r]] <- estimating(dataFull[[r]],biFull[[r]],wdSub,testData[[r]])
        ## plotting(dataFull[[r]], biFull[[r]], wdSub)
        ## save(estFull, dataFull, testData, file=paste(wdSub,"/run.RData",sep=""))

        ## table <- cbind( colnames(gene)[order(estFull[[r]]$q)], estFull[[r]]$q[order(estFull[[r]]$q)], estFull[[r]]$IPatternEst[order(estFull[[r]]$q)])
        ## write.table(table, paste(wdSub, "/estFull",sep=""), sep=" & ", quote=F, col.names=F, row.names=F)


                                        #BI
        set.seed(seed)
        bi[[r]] <- BIcpp(data[[r]], nItr, seed, "BI")
        wdSub <- paste(wd,"/n",n,"_r",r,sep="")
        dir.create(wdSub)
        est[[r]] <- estimating(data[[r]],bi[[r]],wdSub,testData[[r]])
        plotting(data[[r]], bi[[r]], wdSub)
        if(r==1 & thetaMethy==0.5){
            save(bi, est, data, testData, file=paste(wdSub,"/run.RData",sep=""))
        }else{
            save(est, data, testData, file=paste(wdSub,"/run.RData",sep=""))
        }
        table <- cbind( colnames(gene)[order(est[[r]]$q)], est[[r]]$q[order(est[[r]]$q)], est[[r]]$IPatternEst[order(est[[r]]$q)])
        write.table(table, paste(wdSub, "/est",sep=""), sep=" & ", quote=F, col.names=F, row.names=F)

                                        #CC
        set.seed(seed)
        biCC[[r]] <- BIcpp(dataCC[[r]], nItr, seed, "CC")
        wdSub <- paste(wd,"/n",n,"_r",r,"_CC",sep="")
        dir.create(wdSub)
        estCC[[r]] <- estimating(dataCC[[r]],biCC[[r]],wdSub,testData[[r]])
        plotting(dataCC[[r]], biCC[[r]], wdSub)
        save(estCC,dataCC, testData, file=paste(wdSub,"/run.RData",sep=""))
        table <- cbind( colnames(gene)[order(estCC[[r]]$q)], estCC[[r]]$q[order(estCC[[r]]$q)], estCC[[r]]$IPatternEst[order(estCC[[r]]$q)])
        write.table(table, paste(wdSub, "/estCC",sep=""), sep=" & ", quote=F, col.names=F, row.names=F)

        ## for(r in 1:10){
        ##     wd <- paste("./n1_r",r, "_Gene/",sep="")
        ##     load(paste(wd, "run.RData", sep=""))
        ##     table <- cbind( geneName[order(estGene[[r]]$q)], sort(estGene[[r]]$q),
        ##                    estGene[[r]]$IPatternEst[order(estGene[[r]]$q)])
        ##     write.table(table, paste(wd,"estGene",sep=""), sep=" & ", quote=F, col.names=F, row.names=F)
        ## }
                                        #gene only
        if(thetaGene !=0 & thetaMethy!=0){
            set.seed(seed)
            biGene[[r]] <- BIcpp(dataGene[[r]], nItr, seed, "BI")
            wdSub <- paste(wd,"/n",n,"_r",r,"_Gene",sep="")
            dir.create(wdSub)
            estGene[[r]] <- estimating(dataGene[[r]],biGene[[r]],wdSub, testData[[r]])
            plotting(dataGene[[r]], biGene[[r]], wdSub)
            save(estGene, file=paste(wdSub,"/run.RData",sep=""))
        }
        
        ## Cross Validation

        if(0){
            mseGene <- 0
            mse <- 0
            mseCC <- 0
            
            nfold <- 5
            nCompleteSamplecv <- length(obsJointIdx)
            foldscv <- cut(seq(1,nCompleteSamplecv),breaks=nfold,labels=FALSE)
            
            decisions <- rep(0,3)

            wdSub <- paste(wd,"/n",n,"_r",r,"_CV",sep="")
                    dir.create(wdSub)

            for(c in 1:nfold){
                testIdx <- which(foldscv==c)
                trainIdx <- which(foldscv!=c)

                testDatacv[[c]] <- dataCC[[r]]
                testDatacv[[c]]$obsMethyIdx <- 1:length(testIdx)
                testDatacv[[c]]$obsGeneIdx <- 1:length(testIdx)
                testDatacv[[c]]$Y <- dataCC[[r]]$Y[testIdx]
                testDatacv[[c]]$methyObs <- as.matrix(dataCC[[r]]$methyTrue[testIdx,])
                testDatacv[[c]]$geneObs <- as.matrix(dataCC[[r]]$geneTrue[testIdx,])
                testDatacv[[c]]$C <- as.matrix(dataCC[[r]]$C[testIdx,])
                testDatacv[[c]]$geneMTrue <- as.matrix(dataCC[[r]]$geneMTrue[testIdx,])
                testDatacv[[c]]$geneTrue <- as.matrix(dataCC[[r]]$geneTrue[testIdx,])
                testDatacv[[c]]$methyTrue <- as.matrix(dataCC[[r]]$methyTrue[testIdx,])

                if(length(testIdx)==1){
                    testDatacv[[c]]$methyObs <- as.matrix(t(dataCC[[r]]$methyTrue[testIdx,]))
                    testDatacv[[c]]$geneObs <- as.matrix(t(dataCC[[r]]$geneTrue[testIdx,]))
                    testDatacv[[c]]$C <- as.matrix(t(dataCC[[r]]$C[testIdx,]))
                    testDatacv[[c]]$geneMTrue <- as.matrix(t(dataCC[[r]]$geneMTrue[testIdx,]))
                    testDatacv[[c]]$geneTrue <- as.matrix(t(dataCC[[r]]$geneTrue[testIdx,]))
                    testDatacv[[c]]$methyTrue <- as.matrix(t(dataCC[[r]]$methyTrue[testIdx,]))
                }

                    
                datacv[[c]] <- dataCC[[r]]
                if(thetaGene==0){
                    datacv[[c]]$missGeneIdx <- integer(0)
                }else{
                    datacv[[c]]$missGeneIdx <- (length(trainIdx)+1):(length(data[[r]]$missGeneIdx)+length(trainIdx))
                }
                if(thetaMethy==0){
                    datacv[[c]]$missMethyIdx <- integer(0)
                }else{
                    datacv[[c]]$missMethyIdx <- (length(trainIdx)+length(data[[r]]$missGeneIdx)+1) :  (length(trainIdx)+length(data[[r]]$missGeneIdx) + length(data[[r]]$missMethyIdx))
                }
                datacv[[c]]$obsGeneIdx <- c( 1:length(trainIdx), datacv[[c]]$missMethyIdx)
                datacv[[c]]$obsMethyIdx <- c( 1:length(trainIdx),  datacv[[c]]$missGeneIdx)

                datacv[[c]]$Y <- c(dataCC[[r]]$Y[trainIdx], data[[r]]$Y[data[[r]]$missGeneIdx], data[[r]]$Y[data[[r]]$missMethyIdx])
                datacv[[c]]$methyObs <- rbind( as.matrix(dataCC[[r]]$methyTrue[trainIdx,]), as.matrix(data[[r]]$methyTrue[data[[r]]$missGeneIdx,]) )
                datacv[[c]]$geneObs <- rbind( as.matrix(dataCC[[r]]$geneTrue[trainIdx,]), as.matrix(data[[r]]$geneTrue[data[[r]]$missMethyIdx,]) )
                datacv[[c]]$C <- rbind( as.matrix(dataCC[[r]]$C[trainIdx,]),  as.matrix(data[[r]]$C[data[[r]]$missGeneIdx,]), as.matrix(data[[r]]$C[data[[r]]$missMethyIdx,]) )

                datacvCC[[c]] <- dataCC[[r]]
                datacvCC[[c]]$missGeneIdx <- integer(0)
                datacvCC[[c]]$missMethyIdx <- integer(0)
                datacvCC[[c]]$obsGeneIdx <- 1:length(trainIdx)
                datacvCC[[c]]$obsMethyIdx <- 1:length(trainIdx)
                datacvCC[[c]]$Y <- dataCC[[r]]$Y[trainIdx]
                datacvCC[[c]]$methyObs <- as.matrix(dataCC[[r]]$methyTrue[trainIdx,])
                datacvCC[[c]]$geneObs <- as.matrix(dataCC[[r]]$geneTrue[trainIdx,])
                datacvCC[[c]]$C <- as.matrix(dataCC[[r]]$C[trainIdx,])

                datacvGene[[c]] <- dataCC[[r]]
                if(thetaGene==0){
                    datacvGene[[c]]$missGeneIdx <-integer(0)
                }else{
                    datacvGene[[c]]$missGeneIdx <- (length(trainIdx)+1):(length(data[[r]]$missGeneIdx)+length(trainIdx))
                }
                datacvGene[[c]]$missMethyIdx <- integer(0)
                datacvGene[[c]]$obsGeneIdx <- 1:length(trainIdx)
                datacvGene[[c]]$obsMethyIdx <- c( 1:length(trainIdx), datacvGene[[c]]$missGeneIdx)

                datacvGene[[c]]$Y <- c(dataCC[[r]]$Y[trainIdx], data[[r]]$Y[data[[r]]$missGeneIdx])
                datacvGene[[c]]$methyObs <- rbind( as.matrix(dataCC[[r]]$methyTrue[trainIdx,]), as.matrix(data[[r]]$methyTrue[data[[r]]$missGeneIdx,]) )
                datacvGene[[c]]$geneObs <- as.matrix(dataCC[[r]]$geneTrue[trainIdx,])
                datacvGene[[c]]$C <- rbind( as.matrix(dataCC[[r]]$C[trainIdx,]),  as.matrix(data[[r]]$C[data[[r]]$missGeneIdx,]))

                                        #gene only
                if(thetaGene !=0 & thetaMethy!=0){
                    set.seed(seed)
                    bicvGene[[c]] <- BIcpp(datacvGene[[c]], nItr, seed, "BI")
                    estcvGene[[c]] <- estimating(datacvGene[[c]],bicvGene[[c]],wdSub, testDatacv[[c]])
                    mseGene <- estcvGene[[c]]$MSEyHatEst
                }
                                        #BI
                set.seed(seed)
                bicv[[c]] <- BIcpp(datacv[[c]], nItr, seed, "BI")
                estcv[[c]] <- estimating(datacv[[c]],bicv[[c]],wdSub,testDatacv[[c]])
                mse <- estcv[[c]]$MSEyHatEst
                                        #CC

                set.seed(seed)
                bicvCC[[c]] <- BIcpp(datacvCC[[c]], nItr, seed, "CC")
                estcvCC[[c]] <- estimating(datacvCC[[c]],bicvCC[[c]],wdSub,testDatacv[[c]])
                mseCC <- estcvCC[[c]]$MSEyHatEst
 
                save(mse, mseCC,mseGene, estcv, estcvCC, estcvGene, file=paste(wdSub,"/run_",c,".RData",sep=""))

                if(mseGene[1]!=0){
                    best <- which( c(mseCC[4], mse[4], mseGene[4]) == min( c(mseCC[4], mse[4], mseGene[4])) )
                    decisions[best] <- decisions[best]+1
                } else {
                    best<-which( c(mseCC[4], mse[4]) == min( c(mseCC[4], mse[4])) )
                    decisions[best] <- decisions[best]+1
                }

            }
            print(decisions)

            save(decisions, file=paste(wdSub,"/run.RData",sep=""))        
        }   
    }
}



