#!/bin/bash
  #####
  #####  IMDB: Training using three types of unsupervised embedding
  #####
  #####  Step 1. Generate input files.
  #####  Step 2. Training. 
  #####
  #####  NOTE: Unsupervised embedding files are downloaded if sdir=for-semi.
  #####

  #-----------------#
  gpu=-1  # <= change this to, e.g., "gpu=0" to use a specific GPU. 
  mem=2   # pre-allocate 2GB device memory 
  source sh-common.sh
  #-----------------# 
  nm=rcv1
  nm1=rcv1-1m
  sdir=for-semi  # <= Where the unsupervised embedding files are.  Downloaded if sdir=for-semi. 
#  sdir=$outdir  # <= Use the files generated by shcnn-{unsup|parsup|unsup3}-rcv1.sh
  #####
  ##### WARNING: If your system uses Big Endian (Motorola convention), you cannot use the 
  #####    downloaded files!  They are in the little-endian format (Intel convention)!
  #####
  
  dim=100 # dimensionality of unsupervised embeddings
  rcv1dir=rcv1_data 

  options="LowerCase UTF8"
  txt_ext=.txt.tok

  z=4 # to avoid name conflict with other scripts

  #---  Step 0. Prepare unsupervised embedding files.  Downloaded if sdir=for-semi. 
  pch_sz=20
  s_fn0=${nm}-uns-p${pch_sz}.dim${dim}.epo10.ReLayer0       # generated by shcnn-unsup-rcv1.sh 
  s_fn1=${nm}-parsup-p20p${pch_sz}.dim${dim}.epo10.ReLayer0 # generated by shcnn-parsup-rcv1.sh
  s_fn2=${nm}-unsx3-p${pch_sz}.dim${dim}.epo10.ReLayer0     # generated by shcnn-unsup3-rcv1.sh
  for fn in $s_fn0 $s_fn1 $s_fn2; do 
    find_file $sdir $fn; if [ $? != 0 ]; then echo $shnm: find_file failed.; exit 1; fi
  done 
  s_fn0=${sdir}/${s_fn0}; s_fn1=${sdir}/${s_fn1}; s_fn2=${sdir}/${s_fn2}    
  
  #---  Step 1. Generate input files. 
  xvoc1=${tmpdir}/${nm}${z}-trn.vocab
  $exe $gpu write_word_mapping layer0_fn=$s_fn0 layer_type=Weight+ word_map_fn=$xvoc1  # extract word mapping from the unsupervised embedding file. 
  if [ $? != 0 ]; then echo $shnm: write_word_mapping failed.; exit 1; fi

  xvoc3=${tmpdir}/${nm}${z}-trn-123gram.vocab  
  $exe $gpu write_word_mapping layer0_fn=$s_fn2 layer_type=Weight+ word_map_fn=$xvoc3  # extract word mapping from the unsupervised embedding file. 
  if [ $? != 0 ]; then echo $shnm: write_word_mapping failed.; exit 1; fi

  for set in train test; do 
    #---  dataset#0: (bow)
    rnm=${tmpdir}/${nm}${z}-${set}-p${pch_sz}bow   
    $prep_exe gen_regions Bow VariableStride WritePositions \
      region_fn_stem=$rnm input_fn=${rcv1dir}/rcv1-1m-${set} vocab_fn=$xvoc1 \
      $options text_fn_ext=$txt_ext label_fn_ext=.lvl2 \
      label_dic_fn=data/rcv1-lvl2.catdic \
      patch_size=$pch_sz patch_stride=2 padding=$((pch_sz-1))
    if [ $? != 0 ]; then echo $shnm: gen_regions failed.; exit 1; fi

    #---  dataset#1: (bag-of-1-3grams)
    pos_fn=${rnm}.pos  # make regions at the same locations as above. 
    rnm=${tmpdir}/${nm}${z}-${set}-p${pch_sz}x3bow
    $prep_exe gen_regions Bow input_pos_fn=$pos_fn \
      region_fn_stem=$rnm input_fn=${rcv1dir}/rcv1-1m-${set} vocab_fn=$xvoc3 \
      $options text_fn_ext=$txt_ext RegionOnly \
      patch_size=$pch_sz
    if [ $? != 0 ]; then echo $shnm: gen_regions failed.; exit 1; fi
  done


  #---  Step 2. Training. 
  gpumem=${gpu}:4  # pre-allocate 4GB GPU memory. 

  mynm=shcnn-3unsemb-${nm}-dim${dim}
  logfn=${logdir}/${mynm}.log
  csvfn=${csvdir}/${mynm}.csv
  echo 
  echo Supervised training using 3 types of unsupervised embedding to produce additional input.   
  echo This takes a while.  See $logfn and $csvfn for progress. 
  nodes=1000
  num_pool=10
  $exe $gpumem train V2 \
     trnname=${nm}${z}-train-p${pch_sz} tstname=${nm}${z}-test-p${pch_sz} data_dir=$tmpdir \
     dsno0=bow dsno1=x3bow \
     reg_L2=1e-4 step_size=0.25 \
     loss=Square mini_batch_size=100 momentum=0.9 random_seed=1 \
     datatype=sparse \
     num_epochs=100 ss_scheduler=Few ss_decay=0.1 ss_decay_at=80 \
     layers=2 num_sides=3 \
     0layer_type=WeightS+ 0nodes=$nodes 0activ_type=Rect \
     0pooling_type=Avg 0num_pooling=$num_pool 0resnorm_type=Text  \
     1layer_type=Patch 1patch_size=$num_pool \
     0side0_layer_type=Weight+ 0side0_layer_fn=$s_fn0 0side0_dsno=0 \
     0side1_layer_type=Weight+ 0side1_layer_fn=$s_fn1 0side1_dsno=0 \
     0side2_layer_type=Weight+ 0side2_layer_fn=$s_fn2 0side2_dsno=1 \
     evaluation_fn=$csvfn test_interval=25 > $logfn
  if [ $? != 0 ]; then echo $shnm: training failed.; exit 1; fi

  rm -f ${tmpdir}/${nm}${z}*
