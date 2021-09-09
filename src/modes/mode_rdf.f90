MODULE mode_rdf
!
!**********************************************************************************
!*  MODE_RDF                                                                      *
!**********************************************************************************
!* This module computes the radial distribution function (RDF)                    *
!* of a given system. The number of neighbors in a "skin" of radius R and         *
!* of width dR is computed for each atom in the system, then the average          *
!* number of neighbors N is computed. The RDF is then defined as:                 *
!*    RDF(R) = N(R,R+dR) / dR                                                     *
!* When several atom species are present, the partial RDFs are computed.          *
!* E.g. if atoms A and B are present, the distribution of A atoms around          *
!* A atoms will be computed, then B around A, and B around B.                     *
!* The results are output in special files.                                       *
!**********************************************************************************
!* (C) May. 2012 - Pierre Hirel                                                   *
!*     Université de Lille, Sciences et Technologies                              *
!*     UMR CNRS 8207, UMET - C6, F-59655 Villeneuve D'Ascq, France                *
!*     pierre.hirel@univ-lille.fr                                                 *
!* Last modification: P. Hirel - 29 Oct. 2020                                     *
!**********************************************************************************
!* This program is free software: you can redistribute it and/or modify           *
!* it under the terms of the GNU General Public License as published by           *
!* the Free Software Foundation, either version 3 of the License, or              *
!* (at your option) any later version.                                            *
!*                                                                                *
!* This program is distributed in the hope that it will be useful,                *
!* but WITHOUT ANY WARRANTY; without even the implied warranty of                 *
!* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the                  *
!* GNU General Public License for more details.                                   *
!*                                                                                *
!* You should have received a copy of the GNU General Public License              *
!* along with this program.  If not, see <http://www.gnu.org/licenses/>.          *
!**********************************************************************************
!
!Load modules
USE atoms
USE comv
USE constants
USE functions
USE messages
USE neighbors
USE files
USE subroutines
USE readin
USE options
!
!
CONTAINS
!
SUBROUTINE RDF_XYZ(listfile,rdf_maxR,rdf_dr,options_array)
!
!Declare variables
IMPLICIT NONE
!Input
CHARACTER(LEN=*),INTENT(IN):: listfile  !file containing the names of files to analyze
REAL(dp),INTENT(IN):: rdf_maxR            !maximum radius for RDF
REAL(dp),INTENT(IN):: rdf_dr              !width of the "skin"
!
CHARACTER(LEN=2):: sp1, sp2               !species of atoms type 1, type 2
CHARACTER(LEN=128):: msg, temp
CHARACTER(LEN=128):: rdfdat               !Output file names
CHARACTER(LEN=4096):: inputfile           !name of a file to analyze
CHARACTER(LEN=128),DIMENSION(:),ALLOCATABLE:: AUXNAMES !names of auxiliary properties (not used)
CHARACTER(LEN=128),DIMENSION(:),ALLOCATABLE:: options_array !options and their parameters
CHARACTER(LEN=128),DIMENSION(:),ALLOCATABLE:: comment
LOGICAL:: fileexists !does the file exist?
LOGICAL,DIMENSION(:),ALLOCATABLE:: SELECT  !mask for atom list
INTEGER:: atompair
INTEGER:: i, id, j, k, l, m
INTEGER:: u, umin, umax, v, vmin, vmax, w, wmin, wmax
INTEGER:: N1
INTEGER:: Nfiles     !number of files analyzed
INTEGER:: Nneighbors !number of neighbors in the skin
INTEGER:: Nspecies   !number of different atom species in the system
INTEGER:: progress   !To show calculation progress
INTEGER:: rdf_Nsteps !number of "skins" for RDF
INTEGER,DIMENSION(:,:),ALLOCATABLE:: NeighList  !list of neighbours
REAL(dp):: average_dens !average density of the system
REAL(dp):: distance     !distance between 2 atoms
REAL(dp):: rdf_norm     !normalization factor
REAL(dp):: rdf_radius   !radius of the sphere
REAL(dp):: sp1number, sp2number  !atomic number of atoms of type #1, type #2
REAL(dp):: Vsphere, Vskin        !volume of the sphere, skin
REAL(dp):: Vsystem               !volume of the system
REAL(dp),DIMENSION(3,3):: Huc    !Base vectors of unit cell (unknown, set to 0 here)
REAL(dp),DIMENSION(3,3):: H      !Base vectors of the supercell
REAL(dp),DIMENSION(3,3):: ORIENT  !crystal orientation
REAL(dp),DIMENSION(9,9):: C_tensor  !elastic tensor
REAL(dp),DIMENSION(:,:),ALLOCATABLE:: aentries
REAL(dp),DIMENSION(:,:),ALLOCATABLE:: AUX          !auxiliary properties of atoms (not used)
REAL(dp),DIMENSION(:,:),ALLOCATABLE:: P            !atom positions
REAL(dp),DIMENSION(:,:),ALLOCATABLE:: S            !shell positions (not used)
REAL(dp),DIMENSION(:,:),ALLOCATABLE:: rdf_func     !values of the RDF for a given pair of species
REAL(dp),DIMENSION(:,:),ALLOCATABLE:: rdf_total    !final values of the total RDF (space- and time-averaged)
REAL(dp),DIMENSION(:,:),ALLOCATABLE:: V_NN         !positions of 1st NN
REAL(dp),DIMENSION(:,:,:),ALLOCATABLE:: rdf_final  !final values of the partial RDFs (space- and time-averaged)
!
msg = 'ENTERING RDF_XYZ...'
CALL ATOMSK_MSG(999,(/TRIM(msg)/),(/0.d0/))
!
Huc(:,:) = 0.d0
 C_tensor(:,:) = 0.d0
!
CALL ATOMSK_MSG(4051,(/""/),(/rdf_dr/))
!
!Initialize variables
IF(ALLOCATED(SELECT)) DEALLOCATE(SELECT)
atompair=0
ORIENT(:,:) = 0.d0
IF(ALLOCATED(rdf_func)) DEALLOCATE(rdf_func)
IF(ALLOCATED(rdf_final)) DEALLOCATE(rdf_final)
IF(ALLOCATED(rdf_total)) DEALLOCATE(rdf_total)
!
!
!
100 CONTINUE
CALL CHECKFILE(listfile,'read')
OPEN(UNIT=50,FILE=listfile,STATUS='OLD',FORM='FORMATTED')
REWIND(50)
!
!
!
200 CONTINUE
!Compute the RDFs, space-average for each file, and time-average over all files
!Note: if several atom species exist the partial RDFs must be computed,
!     i.e. for all couples of species (k,l) with l>=k.
Nfiles=0
DO
  !
  !Read the name of the file containing the system to analyze
  READ(50,'(a128)',END=300,ERR=300) inputfile
  inputfile = ADJUSTL(inputfile)
  !
  IF( temp(1:1).NE.'#' ) THEN
    !Check if file actually exists
    INQUIRE(FILE=inputfile,EXIST=fileexists)
    !
    IF(fileexists) THEN
      Nfiles = Nfiles+1
      !Read atom positions
      CALL READ_AFF(inputfile,H,P,S,comment,AUXNAMES,AUX)
      !
      !We won't use shell positions nor auxiliary properties: free memory
      IF(ALLOCATED(S)) DEALLOCATE(S)
      IF(ALLOCATED(AUXNAMES)) DEALLOCATE(AUXNAMES)
      IF(ALLOCATED(AUX)) DEALLOCATE(AUX)
      !
      !Apply options to the system
      CALL OPTIONS_AFF(options_array,Huc,H,P,S,AUXNAMES,AUX,ORIENT,SELECT,C_tensor)
      IF(nerr>0) GOTO 1000
      !
      !Compute total volume of the system
      CALL VOLUME_PARA(H,Vsystem)
      !
      !Determine if we have to look for periodic replica of atoms
      !Minimum image convention: look for all replica in the radius rdf_maxR
      umin=0
      umax=0
      vmin=0
      vmax=0
      wmin=0
      wmax=0
      IF ( VECLENGTH(H(1,:))<=rdf_maxR ) THEN
        umax = CEILING( rdf_maxR / VECLENGTH(H(1,:)) )
        umin = -1*umax
      ENDIF
      IF ( VECLENGTH(H(2,:))<=rdf_maxR ) THEN
        vmax = CEILING( rdf_maxR / VECLENGTH(H(2,:)) )
        vmin = -1*vmax
      ENDIF
      IF ( VECLENGTH(H(3,:))<=rdf_maxR ) THEN
        wmax = CEILING( rdf_maxR / VECLENGTH(H(3,:)) )
        wmin = -1*wmax
      ENDIF
      !
      !Construct neighbour list
      CALL ATOMSK_MSG(11,(/""/),(/0.d0/))
      CALL NEIGHBOR_LIST(H,P,rdf_maxR,NeighList)
      !
      !Set number of steps
      rdf_Nsteps = NINT(rdf_maxR/rdf_dr)+1
      !
      !If it is the first system, initialize arrays and variables
      IF(Nfiles==1) THEN
        !Count how many different species exist in the system
        CALL FIND_NSP(P(:,4),aentries)
        Nspecies = SIZE(aentries,1)
        WRITE(msg,*) 'Nspecies = ', Nspecies
        CALL ATOMSK_MSG(999,(/TRIM(msg)/),(/0.d0/))
        !
        !Allocate array to store the RDF for current system
        ALLOCATE( rdf_func(rdf_Nsteps,2) )
        rdf_func(:,:) = 0.d0
        !Allocate array to store the final, time-averaged RDF
        ALLOCATE( rdf_final( Nspecies*(Nspecies+1)/2,rdf_Nsteps,2 ) )
        rdf_final(:,:,:) = 0.d0
      ENDIF
      !
      !
      atompair=0
      DO k=1,Nspecies  !loop on all atom species
        !
        sp1number = aentries(k,1)
        CALL ATOMSPECIES(sp1number,sp1)
        !
        DO l=k,Nspecies
          !Initialize variables
          atompair=atompair+1
          rdf_func(:,:) = 0.d0
          !
          !Compute average density of atoms of species 2 the system
          average_dens = aentries(l,2) / Vsystem
          !
          sp2number = aentries(l,1)
          CALL ATOMSPECIES(sp2number,sp2)
          !
          !Set name of output file
          IF(Nspecies>1) THEN
            rdfdat = 'rdf_'//TRIM(sp1)//TRIM(sp2)//'.dat'
          ELSE
            rdfdat = 'rdf.dat'
          ENDIF
          !
          CALL ATOMSK_MSG(4052,(/sp1,sp2/),(/0.d0/))
          IF( aentries(k,2)>5000 ) THEN
            CALL ATOMSK_MSG(3,(/''/),(/0.d0/))
          ENDIF
          !
          !Compute the partial RDF of atoms sp2 around atoms sp1
          progress = 0
          !!!$OMP PARALLEL DO DEFAULT(SHARED) &
          !!!$OMP& PRIVATE(i,id,j,k,l,m,u,v,w,distance,Nneighbors,Vsphere,Vskin,rdf_radius,rdf_norm) &
          !!!$OMP& REDUCTION(+:progress)
          DO j=1,MIN(rdf_Nsteps,SIZE(rdf_func,1))
            !Initialize variables
            Nneighbors = 0
            Vskin = 0.d0
            progress=progress+1
            !
            IF( rdf_Nsteps*aentries(k,2)>10000 ) THEN
              !If there are many atoms, display a fancy progress bar
              CALL ATOMSK_MSG(10,(/""/),(/DBLE(progress),DBLE(rdf_Nsteps)/))
            ENDIF
            !
            !Set radius of current sphere
            rdf_radius = DBLE(j) * rdf_dr
            !
            !Compute volume of current sphere and skin
            Vsphere = (4.d0/3.d0)*pi*rdf_radius**3
            Vskin = (4.d0/3.d0)*pi*(rdf_radius+rdf_dr)**3 - Vsphere
            !
            !Count atoms of species 2 within the skin
            DO i=1,SIZE(P,1)
              !
              IF( DABS(P(i,4)-sp1number)<1.d-9 ) THEN
                !Atom i is of the required species sp1
                !
                !First, check for replica of atom i
                !(only if atom i is of the same species as atom j, and do not count atom i itself)
                IF( DABS(P(i,4)-sp2number)<1.d-9 ) THEN
                  DO u=umin, umax
                    DO v=vmin, vmax
                      DO w=wmin, wmax
                        distance = VECLENGTH( P(i,1:3) - &
                                  & (P(i,1:3) + DBLE(u)*H(1,:) + DBLE(v)*H(2,:) + DBLE(w)*H(3,:)) )
                        IF( DABS(distance)>1.d-12 .AND. distance>=rdf_radius .AND. distance<rdf_radius+rdf_dr ) THEN
                          !This replica is inside the skin
                          Nneighbors = Nneighbors + 1
                        ENDIF
                      ENDDO
                    ENDDO
                  ENDDO
                ENDIF
                !
                !Parse the neighbour list of atom #i,
                !count only atoms of species sp2
                m=1
                DO WHILE ( m<=SIZE(NeighList,2) .AND. NeighList(i,m).NE.0 )
                  id = NeighList(i,m)
                  IF( DABS( P(id,4)-sp2number) < 1.d-9 ) THEN
                    !This atom is of species sp2
                    !Look if this atoms and/or its periodic replica are inside the skin R,R+dR
                    DO u=umin, umax
                      DO v=vmin, vmax
                        DO w=wmin, wmax
                          distance = VECLENGTH( P(i,1:3) - &
                                   & (P(id,1:3) + DBLE(u)*H(1,:) + DBLE(v)*H(2,:) + DBLE(w)*H(3,:)) )
                          IF( distance>=rdf_radius .AND. distance<rdf_radius+rdf_dr ) THEN
                            !This replica is inside the skin
                            Nneighbors = Nneighbors + 1
                          ENDIF
                        ENDDO
                      ENDDO
                    ENDDO
                  ENDIF
                  m=m+1
                ENDDO
                !
              ENDIF
            ENDDO !i
            !
            !  average_dens = NINT(aentries(k,2)) / Vsystem
            rdf_norm = NINT(aentries(k,2)) * average_dens * Vskin
            !
            !Compute the average number of neighbors for this radius
            !and save it in the final RDF
            rdf_func(j,1) = rdf_radius
            rdf_func(j,2) = Nneighbors / rdf_norm   !radial density function
            !
          ENDDO  !sphere radii (j)
          !!!!$OMP END PARALLEL DO
          !
          !rdf_func contains the space-averaged RDF for current system and for
          !current pair of atoms (k,l)
          !Add it into rdf_final (it will be time-averaged later, see label 300)
          rdf_final(atompair,:,:) = rdf_func(:,:)
          !rdf_final(atompair,:,2) = rdf_final(atompair,:,2) + rdf_func(:,2)
          !
        ENDDO  !atom species l
      ENDDO   !atom species k
      !
      IF(ALLOCATED(P)) DEALLOCATE(P)
      IF(ALLOCATED(NeighList)) DEALLOCATE(NeighList)
      !
    ELSE
      !Input file doesn't exist: output a warning and go to the next file
      nwarn=nwarn+1
      CALL ATOMSK_MSG(4700,(/TRIM(inputfile)/),(/0.d0/))
    ENDIF
    !
  ENDIF
  !
ENDDO  !loop on m files
!
!
!
300 CONTINUE
CLOSE(50)
!
IF(Nfiles<=0) THEN
  !no file was analyzed => exit
  nerr=nerr+1
  GOTO 1000
ENDIF
!
!rdf_final contains the partial RDFs
!=> divide by the number of systems that were analyzed to make the time-average
rdf_final(:,:,2) = rdf_final(:,:,2) / Nfiles
!
!rdf_final contains the partial RDFs
!Compute the total RDF
ALLOCATE( rdf_total(SIZE(rdf_final,2),SIZE(rdf_final,3)) )
rdf_total(:,:) = 0.d0
DO i=1,SIZE(rdf_final,1)
  rdf_total(:,:) = rdf_total(:,:) + rdf_final(i,:,:)
ENDDO
rdf_total(:,:) = rdf_total(:,:) / SIZE(rdf_final,1)
!
!
!
400 CONTINUE
!Knowing the RDF, compute the structure factor S
!=Fourier transform of the total correlation function

!
!
!
500 CONTINUE
!Output partial RDFs to files
IF(Nspecies>1) THEN
  atompair=0
  DO k=1,Nspecies
    DO l=k,Nspecies
      atompair=atompair+1
      !
      CALL ATOMSPECIES(aentries(k,1),sp1)
      CALL ATOMSPECIES(aentries(l,1),sp2)
      rdfdat = 'rdf_'//TRIM(sp1)//TRIM(sp2)//'.dat'
      IF(.NOT.overw) CALL CHECKFILE(rdfdat,'writ')
      OPEN(UNIT=40,FILE=rdfdat)
      !
      DO i=1,SIZE(rdf_final,2)
        WRITE(40,'(2f24.8)') rdf_final(atompair,i,1), rdf_final(atompair,i,2)
      ENDDO
      !
      CLOSE(40)
      CALL ATOMSK_MSG(4039,(/rdfdat/),(/0.d0/))
    ENDDO
  ENDDO
ENDIF
!
!Output total RDF
rdfdat = 'rdf_total.dat'
IF(.NOT.overw) CALL CHECKFILE(rdfdat,'writ')
OPEN(UNIT=40,FILE=rdfdat)
DO i=1,SIZE(rdf_total,1)
  WRITE(40,'(2f24.8)') rdf_total(i,1), rdf_total(i,2)
ENDDO
CLOSE(40)
CALL ATOMSK_MSG(4039,(/rdfdat/),(/0.d0/))
!
!
!
GOTO 1000
CALL ATOMSK_MSG(4053,(/""/),(/0.d0/))
!
!
!
1000 CONTINUE
IF(ALLOCATED(rdf_func)) DEALLOCATE(rdf_func)
IF(ALLOCATED(rdf_final)) DEALLOCATE(rdf_final)
IF(ALLOCATED(rdf_total)) DEALLOCATE(rdf_total)
!
!
END SUBROUTINE RDF_XYZ
!
!
END MODULE mode_rdf
