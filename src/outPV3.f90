!$Id$
module outPV3

   use truncation, only: n_m_max, n_phi_max, n_r_max, nrp, lm_max, &
                         l_max, minc, m_max
   use radial_functions, only: cheb_norm, r_ICB, i_costf_init, &
                               d_costf_init, r_CMB
   use physical_parameters, only: radratio
   use blocking, only: lm2, lm2m, lm2l, lm2mc
   use horizontal_data, only: dLh, dPhi
   use logic, only: lVerbose, l_SRIC
   use output_data, only: tag, sDens
   use plms_theta, only: plm_theta
   use const, only: pi
#if (FFTLIB==JW)
   use fft_JW, only: fft_to_real
#elif (FFTLIB==MKL)
   use fft_MKL, only: fft_to_real
#endif
   use TO_helpers, only: getPAStr
   use cosine_transform, only: costf1
 
   implicit none 
 
   private
 
   integer, parameter :: nSmaxA=97
   integer, parameter :: nZmaxA=2*nSmaxA
   real(kind=8), allocatable :: rZ(:,:)
   real(kind=8), allocatable :: PlmS(:,:,:)
   real(kind=8), allocatable :: dPlmS(:,:,:)
   real(kind=8), allocatable :: PlmZ(:,:,:)
   real(kind=8), allocatable :: dPlmZ(:,:,:)
   real(kind=8), allocatable :: OsinTS(:,:)
   real(kind=8), allocatable :: VorOld(:,:,:)
 
   public :: initialize_outPV3, outPV
  
contains

   subroutine initialize_outPV3

      allocate( rZ(nZmaxA/2+1,nSmaxA) )
      allocate( PlmS(l_max+1,nZmaxA/2+1,nSmaxA) )
      allocate( dPlmS(l_max+1,nZmaxA/2+1,nSmaxA) )
      allocate( PlmZ(lm_max,nZmaxA/2+1,nSmaxA) )
      allocate( dPlmZ(lm_max,nZmaxA/2+1,nSmaxA) )
      allocate( OsinTS(nZmaxA/2+1,nSmaxA) )
      allocate( VorOld(nrp,nZmaxA,nSmaxA) )

   end subroutine initialize_outPV3
!---------------------------------------------------------------------------------
   subroutine outPV(time,l_stop_time,nPVsets,w,dw,ddw,z,dz,omega_IC,omega_MA)
      !-----------------------------------------------------------------------
      !   Output of z-integrated axisymmetric rotation rate Vp/s 
      !   and s derivatives
      !-----------------------------------------------------------------------

      !-- Input of variables:
      real(kind=8),    intent(in) :: time
      real(kind=8),    intent(in) :: omega_IC,omega_MA
      logical,         intent(in) :: l_stop_time
      complex(kind=8), intent(in) :: w(lm_max,n_r_max)
      complex(kind=8), intent(in) :: dw(lm_max,n_r_max)
      complex(kind=8), intent(in) :: ddw(lm_max,n_r_max)
      complex(kind=8), intent(in) :: z(lm_max,n_r_max)
      complex(kind=8), intent(in) :: dz(lm_max,n_r_max)

      integer, intent(inout) :: nPVsets

      !-- (l,r) Representation of the different contributions
      real(kind=8) :: dzVpLMr(l_max+1,n_r_max)

      !--- Work array:
      complex(kind=8) :: workA(lm_max,n_r_max)
      real(kind=8) :: workAr(lm_max,n_r_max)

      integer :: lm,l,m ! counter for degree and order

      real(kind=8) :: fac

      !--- define Grid
      integer :: nSmax,nS,nSI
      real(kind=8) ::  sZ(nSmaxA),dsZ ! cylindrical radius s and s-step

      integer :: nZ,nZmax,nZmaxNS
      integer, save :: nZC(nSmaxA),nZ2(nZmaxA,nSmaxA)
      integer, save :: nZS
      real(kind=8) :: zZ(nZmaxA),zstep!,zZC
      real(kind=8) :: VpAS(nZmaxA),omS(nZmaxA)

      !-- Plms: Plm,sin
      integer :: nR,nPhi,nC
      real(kind=8) :: thetaZ,rZS!,sinT,cosT

      !-- For PV output files: 
      character(len=80) :: fileName

      !-- Output of all three field components:
      real(kind=8) :: VsS(nrp,nZmaxA)
      real(kind=8) :: VpS(nrp,nZmaxA)
      real(kind=8) :: VzS(nrp,nZmaxA)
      real(kind=8) :: VorS(nrp,nZmaxA)
      real(kind=8) :: dpVorS(nrp,nZmaxA)
      real(kind=4) :: out1(n_phi_max*nZmaxA)
      real(kind=4) :: out2(n_phi_max*nZmaxA)
      real(kind=4) :: out3(n_phi_max*nZmaxA)
      real(kind=4) :: out4(n_phi_max*nZmaxA)
      real(kind=4) :: out5(n_phi_max*nZmaxA)
      real(kind=8), save :: timeOld

      !-- This may be deleted later:
      complex(kind=8) :: wP(lm_max,n_r_max)
      complex(kind=8) :: dwP(lm_max,n_r_max)
      complex(kind=8) :: ddwP(lm_max,n_r_max)
      complex(kind=8) :: zP(lm_max,n_r_max)
      complex(kind=8) :: dzP(lm_max,n_r_max)


      if ( lVerbose ) write(*,*) '! Starting outPV!'

      nPVsets=nPVsets+1

      !-- Start with calculating advection due to axisymmetric flows:

      nSmax=n_r_max+int(r_ICB*dble(n_r_max))
      nSmax=int(sDens*nSmax)
      if ( nSmax > nSmaxA ) then
         write(*,*) 'Increase nSmaxA in outPV!'
         write(*,*) 'Should be at least nSmax=',nSmax
         write(*,*) 'But is only=',nSmaxA
         stop
      end if
      nZmax=2*nSmax

      if ( l_stop_time ) then
         if ( l_SRIC  .and. omega_IC /= 0 ) then
            fac=1.D0/omega_IC
         else
            fac=1.D0
         end if
         do nR=1,n_r_max
            do l=1,l_max
               lm=lm2(l,0)
               dzVpLMr(l+1,nR)=fac*real(z(lm,nR))
            end do
         end do

         !---- Transform the contributions to cheb space:
         call costf1(dzVpLMr,l_max+1,1,l_max+1,workAr,i_costf_init,d_costf_init)
      end if

      !--- Transforming of field without the backtransform
      !    Thus this must be the last thing done with the 
      !    fields in a run. See m_output.F90 and m_step_time.F90.
      !    NOTE: output is only non-axisymmetric part!
      do nR=1,n_r_max
         do lm=1,lm_max
            m=lm2m(lm)
            !           if ( m == 0 ) then
            !             wP(lm,nR)  =0.D0
            !              dwP(lm,nR) =0.D0
            !              ddwP(lm,nR)=0.D0
            !              zP(lm,nR)  =0.D0
            !              dzP(lm,nR) =0.D0
            !          else
            wP(lm,nR)  =w(lm,nR)*dLh(lm)
            dwP(lm,nR) =dw(lm,nR)
            ddwP(lm,nR)=ddw(lm,nR)
            zP(lm,nR)  =z(lm,nR)
            dzP(lm,nR) =dz(lm,nR)
            !          end if
         end do
      end do

      !---- Transform the contributions to cheb space for z-integral:
      call costf1(wP,lm_max,1,lm_max,workA,i_costf_init,d_costf_init)
      call costf1(dwP,lm_max,1,lm_max,workA,i_costf_init,d_costf_init)
      call costf1(ddwP,lm_max,1,lm_max,workA,i_costf_init,d_costf_init)
      call costf1(zP,lm_max,1,lm_max,workA,i_costf_init,d_costf_init)
      call costf1(dzP,lm_max,1,lm_max,workA,i_costf_init,d_costf_init)

      dsZ=r_CMB/dble(nSmax)  ! Step in s controlled by nSmax
      nSI=0                  ! Inner core position
      do nS=1,nSmax
         sZ(nS)=(nS-0.5D0)*dsZ
         if ( sZ(nS) < r_ICB .and. nS > nSI ) nSI=nS
      end do
      zstep=2*r_CMB/dble(nZmax-1)
      do nZ=1,nZmax
         zZ(nZ)=r_CMB-(nZ-1)*zstep
      end do

      !--- Open file for output:
      if ( l_stop_time ) then
         fileName='PVZ.'//TAG
         open(95,file=fileName, form='unformatted', status='unknown')
         write(95) sngl(time), FLOAT(nSmax), FLOAT(nZmax), sngl(omega_IC),sngl(omega_ma)
         write(95) (sngl(sZ(nS)),nS=1,nSmax)
         write(95) (sngl(zZ(nZ)),nZ=1,nZmax)


         !--- Open file for the three flow components:
         fileName='Vcy.'//TAG
         open(96,file=fileName,form='unformatted', status='unknown')
         write(96) sngl(time),FLOAT(nSmax), FLOAT(nZmax),              &
              &      FLOAT(n_phi_max), sngl(omega_IC), sngl(omega_ma), &
              &      sngl(radratio),FLOAT(minc)
         write(96) (sngl(sZ(nS)),nS=1,nSmax)
         write(96) (sngl(zZ(nZ)),nZ=1,nZmax)
      end if



      do nS=1,nSmax

         !------ Get r,theta,Plm,dPlm for northern hemishere:
         if ( nPVsets == 1 ) then ! do this only for the first call !
            nZC(nS)=0 ! Points within shell
            do nZ=1,nZmax
               rZS=dsqrt(zZ(nZ)**2+sZ(nS)**2)
               if ( rZS >= r_ICB .and. rZS <= r_CMB ) then
                  nZC(nS)=nZC(nS)+1  ! Counts all z within shell
                  nZ2(nZ,nS)=nZC(nS) ! No of point within shell
                  if ( zZ(nZ) > 0 ) then ! Onl north hemisphere
                     rZ(nZC(nS),nS)=rZS
                     thetaZ=DATAN2(sZ(nS),zZ(nZ))
                     OsinTS(nZC(nS),nS)=1.D0/DSIN(thetaZ)
                     call plm_theta(thetaZ,l_max,0,minc,              &
                          &    PlmS(1,nZC(nS),nS),dPlmS(1,nZC(nS),nS),l_max+1,2)
                     call plm_theta(thetaZ,l_max,m_max,minc,          &
                          &        PlmZ(1,nZC(nS),nS),dPlmZ(1,nZC(nS),nS),lm_max,2)
                  end if
               else
                  nZ2(nZ,nS)=-1 ! No z found within shell !
               end if
            end do
         end if

         !-- Get azimuthal flow component in the shell
         nZmaxNS=nZC(nS) ! all z points within shell
         if ( l_stop_time ) then
            call getPAStr(VpAS,dzVpLMr,nZmaxNS,nZmaxA,l_max+1,      &
                 &        l_max,r_ICB,r_CMB,n_r_max,                &
                 &        rZ(1,nS),dPlmS(1,1,nS),OsinTS(1,nS))

            !-- Copy to array with all z-points
            do nZ=1,nZmax
               rZS=dsqrt(zZ(nZ)**2+sZ(nS)**2)
               nZS=nZ2(nZ,nS)
               if ( nZS > 0 ) then
                  omS(nZ)=VpAS(nZS)/sZ(nS)
               else
                  if ( rZS <= r_ICB ) then
                     omS(nZ)=1.D0
                  else
                     omS(nZ)=fac*omega_MA
                  end if
               end if
            end do
         end if

         !-- Get all three components in the shell
         call getPVptr(wP,dwP,ddwP,zP,dzP,r_ICB,r_CMB,rZ(1,nS),                 &
              &        nZmaxNS,nZmaxA,PlmZ(1,1,nS),dPlmZ(1,1,nS),OsinTS(1,nS),  &
              &        VsS,VpS,VzS,VorS,dpVorS)

         if ( l_stop_time ) then
            write(95) (sngl(omS(nZ)),nZ=1,nZmax)
            write(96) FLOAT(nZmaxNS)
            nC=0
            do nZ=1,nZmaxNS
               do nPhi=1,n_phi_max
                  nC=nC+1
                  out1(nC)=sngl(VsS(nPhi,nZ)) ! Vs
                  out2(nC)=sngl(VpS(nPhi,nZ)) ! Vphi
                  out3(nC)=sngl(VzS(nPhi,nZ)) ! Vz
                  out4(nC)=sngl(VorS(nPhi,nZ))
                  out5(nC)=(sngl(VorS(nPhi,nZ)-VorOld(nPhi,nZ,nS)))/(sngl(time-timeOld))
               end do
            end do
            write(96) (out1(nZ),nZ=1,nC)
            write(96) (out2(nZ),nZ=1,nC)
            write(96) (out3(nZ),nZ=1,nC)
            write(96) (out4(nZ),nZ=1,nC)
            write(96) (out5(nZ),nZ=1,nC)
         else
            timeOld=time
            do nZ=1,nZmaxNS
               do nPhi=1,n_phi_max
                  VorOld(nPhi,nZ,nS)=VorS(nPhi,nZ)
               end do
            end do
         end if

      end do  ! Loop over s 

      if ( l_stop_time ) CLOSE (95)
      if ( l_stop_time ) close(96)

   end subroutine outPV
!---------------------------------------------------------------------------------
   subroutine getPVptr(w,dw,ddw,z,dz,rMin,rMax,rS, &
                   nZmax,nZmaxA,PlmS,dPlmS,OsinTS, &
                          VrS,VpS,VtS,VorS,dpVorS)
      !-------------------------------------------------------------------------------
      !  This subroutine calculates the three flow conponents VrS,VtS,VpS at
      !  (r,theta,all phis) and (r,pi-theta, all phis). Here r=rS, PlmS=Plm(theta),
      !  dPlmS=sin(theta)*dTheta Plm(theta), and OsinTS=1/sin(theta).
      !  The flow is calculated for all n_phi_max azimuthal points used in the code,
      !  and for corresponding latitudes north and south of the equator.
      !  For lDeriv=.true. the subroutine also calculates dpEk and dzEk which
      !  are phi averages of (d Vr/d phi)**2 + (d Vtheta/ d phi)**2 + (d Vphi/ d phi)**2
      !  and (d Vr/d z)**2 + (d Vtheta/ d z)**2 + (d Vphi/ d z)**2, respectively.
      !  These two quantities are used ot calculate z and phi scale of the flow in
      !  s_getEgeos.f
      !  NOTE: on input w=l*(l+1)*w
      !-------------------------------------------------------------------------------

      !--- Input variables:
      complex(kind=8), intent(in) :: w(lm_max,n_r_max)
      complex(kind=8), intent(in) :: dw(lm_max,n_r_max)
      complex(kind=8), intent(in) :: ddw(lm_max,n_r_max)
      complex(kind=8), intent(in) :: z(lm_max,n_r_max)
      complex(kind=8), intent(in) :: dz(lm_max,n_r_max)
      real(kind=8),    intent(in) :: rMin,rMax  ! radial bounds
      integer,         intent(in) :: nZmax,nZmaxA ! number of (r,theta) points
      real(kind=8),    intent(in) :: rS(nZmaxA)
      real(kind=8),    intent(in) :: PlmS(lm_max,nZmaxA/2+1)
      real(kind=8),    intent(in) :: dPlmS(lm_max,nZmaxA/2+1)
      real(kind=8),    intent(in) :: OsinTS(nZmaxA/2+1)

      !--- Output: function on azimuthal grid points defined by FT!
      real(kind=8), intent(out) :: VrS(nrp,nZmaxA)
      real(kind=8), intent(out) :: VtS(nrp,nZmaxA)
      real(kind=8), intent(out) :: VpS(nrp,nZmaxA)
      real(kind=8), intent(out) :: VorS(nrp,nZmaxA)
      real(kind=8), intent(out) :: dpVorS(nrp,nZmaxA)

      !--- Local:
      real(kind=8) :: chebS(n_r_max)
      integer :: nS,nN,mc,lm,l,m,nCheb
      real(kind=8) :: x,phiNorm,mapFac,OS,cosT,sinT,Or_e1,Or_e2
      complex(kind=8) :: Vr,Vt,Vt1,Vt2,Vp1,Vp2,Vor,Vot1,Vot2
      real(kind=8) :: VotS(nrp,nZmaxA)
      complex(kind=8) :: wSr,dwSr,ddwSr,zSr,dzSr
      complex(kind=8) :: dp

      mapFac=2.D0/(rMax-rMin)
      phiNorm=2.D0*pi/n_phi_max

      do nS=1,nZmax
         do mc=1,nrp
            VrS(mc,nS) =0.d0
            VtS(mc,nS) =0.D0
            VpS(mc,nS) =0.D0
            VorS(mc,nS)=0.D0
            VotS(mc,nS)=0.D0
         end do
      end do

      do nN=1,nZmax/2    ! Loop over all (r,theta) points in NHS
         nS=nZmax-nN+1   ! Southern counterpart !

         !------ Calculate Chebs:
         !------ Map r to cheb intervall [-1,1]:
         !       and calculate the cheb polynomia:
         !       Note: the factor cheb_norm is needed
         !       for renormalisation. Its not needed if one used
         !       costf1 for the back transform.
         x=2.D0*(rS(nN)-0.5D0*(rMin+rMax))/(rMax-rMin)
         chebS(1) =1.D0*cheb_norm ! Extra cheb_norm cheap here
         chebS(2) =x*cheb_norm
         do nCheb=3,n_r_max
            chebS(nCheb)=2.D0*x*chebS(nCheb-1)-chebS(nCheb-2)
         end do
         chebS(1)      =0.5D0*chebS(1)
         chebS(n_r_max)=0.5D0*chebS(n_r_max)
         Or_e2=1.D0/rS(nN)**2

         do lm=1,lm_max     ! Sum over lms
            l =lm2l(lm)
            m =lm2m(lm)
            mc=lm2mc(lm)
            wSr  =cmplx(0.D0,0.D0,kind=kind(0d0))
            dwSr =cmplx(0.D0,0.D0,kind=kind(0d0))
            ddwSr=cmplx(0.D0,0.D0,kind=kind(0d0))
            zSr  =cmplx(0.D0,0.D0,kind=kind(0d0))
            dzSr =cmplx(0.D0,0.D0,kind=kind(0d0))
            do nCheb=1,n_r_max
               wSr  =  wSr+  w(lm,nCheb)*chebS(nCheb)
               dwSr = dwSr+ dw(lm,nCheb)*chebS(nCheb)
               ddwSr=ddwSr+ddw(lm,nCheb)*chebS(nCheb)
               zSr  =  zSr+  z(lm,nCheb)*chebS(nCheb)
               dzSr = dzSr+ dz(lm,nCheb)*chebS(nCheb)
            end do
            Vr  =  wSr* PlmS(lm,nN)
            Vt1 = dwSr*dPlmS(lm,nN)
            Vt2 =  zSr* PlmS(lm,nN)*dPhi(lm)
            Vp1 = dwSr* PlmS(lm,nN)*dPhi(lm)
            Vp2 = -zSr*dPlmS(lm,nN)
            Vor =  zSr* PlmS(lm,nN)*dLh(lm)
            Vot1= dzSr*dPlmS(lm,nN)
            Vot2= (wSr*Or_e2-ddwSr)*PlmS(lm,nN)*dPhi(lm)
            VrS(2*mc-1, nN)=VrS(2*mc-1, nN)+ real(Vr)
            VrS(2*mc  , nN)=VrS(2*mc  , nN)+aimag(Vr)
            VtS(2*mc-1, nN)=VtS(2*mc-1, nN)+ real(Vt1+Vt2)
            VtS(2*mc  , nN)=VtS(2*mc  , nN)+aimag(Vt1+Vt2)
            VpS(2*mc-1, nN)=VpS(2*mc-1, nN)+ real(Vp1+Vp2)
            VpS(2*mc  , nN)=VpS(2*mc  , nN)+aimag(Vp1+Vp2)
            VorS(2*mc-1,nN)=VorS(2*mc-1,nN)+ real(Vor)
            VorS(2*mc  ,nN)=VorS(2*mc  ,nN)+aimag(Vor)
            VotS(2*mc-1,nN)=VotS(2*mc-1,nN)+ real(Vot1+Vot2)
            VotS(2*mc  ,nN)=VotS(2*mc  ,nN)+aimag(Vot1+Vot2)
            if ( mod(l+m,2) == 0 ) then
               VrS(2*mc-1,nS) =VrS(2*mc-1,nS) + real(Vr)
               VrS(2*mc  ,nS) =VrS(2*mc  ,nS) +aimag(Vr)
               VtS(2*mc-1,nS) =VtS(2*mc-1,nS) + real(Vt2-Vt1)
               VtS(2*mc  ,nS) =VtS(2*mc  ,nS) +aimag(Vt2-Vt1)
               VpS(2*mc-1,nS) =VpS(2*mc-1,nS) + real(Vp1-Vp2)
               VpS(2*mc  ,nS) =VpS(2*mc  ,nS) +aimag(Vp1-Vp2)
               VorS(2*mc-1,nS)=VorS(2*mc-1,nS)+ real(Vor)
               VorS(2*mc  ,nS)=VorS(2*mc  ,nS)+aimag(Vor)
               VotS(2*mc-1,nS)=VotS(2*mc-1,nS)+ real(Vot2-Vot1)
               VotS(2*mc  ,nS)=VotS(2*mc  ,nS)+aimag(Vot2-Vot1)
            else
               VrS(2*mc-1,nS) =VrS(2*mc-1,nS) - real(Vr)
               VrS(2*mc  ,nS) =VrS(2*mc  ,nS) -aimag(Vr)
               VtS(2*mc-1,nS) =VtS(2*mc-1,nS) + real(Vt1-Vt2)
               VtS(2*mc  ,nS) =VtS(2*mc  ,nS) +aimag(Vt1-Vt2)
               VpS(2*mc-1,nS) =VpS(2*mc-1,nS) + real(Vp2-Vp1)
               VpS(2*mc  ,nS) =VpS(2*mc  ,nS) +aimag(Vp2-Vp1)
               VorS(2*mc-1,nS)=VorS(2*mc-1,nS)- real(Vor)
               VorS(2*mc  ,nS)=VorS(2*mc  ,nS)-aimag(Vor)
               VotS(2*mc-1,nS)=VotS(2*mc-1,nS)+ real(Vot1-Vot2)
               VotS(2*mc  ,nS)=VotS(2*mc  ,nS)+aimag(Vot1-Vot2)
            end if
         end do

      end do

      if ( mod(nZmax,2) == 1 ) then ! Remaining equatorial point
         nS=(nZmax+1)/2

         x=2.D0*(rS(nS)-0.5D0*(rMin+rMax))/(rMax-rMin)
         chebS(1)=1.D0*cheb_norm ! Extra cheb_norm cheap here
         chebS(2)=x*cheb_norm
         do nCheb=3,n_r_max
            chebS(nCheb)=2.D0*x*chebS(nCheb-1)-chebS(nCheb-2)
         end do
         chebS(1)      =0.5D0*chebS(1)
         chebS(n_r_max)=0.5D0*chebS(n_r_max)
         Or_e2=1.D0/rS(nS)**2

         do lm=1,lm_max     ! Sum over lms
            l =lm2l(lm)
            m =lm2m(lm)
            mc=lm2mc(lm)
            wSr  =cmplx(0.D0,0.D0,kind=kind(0d0))
            dwSr =cmplx(0.D0,0.D0,kind=kind(0d0))
            ddwSr=cmplx(0.D0,0.D0,kind=kind(0d0))
            zSr  =cmplx(0.D0,0.D0,kind=kind(0d0))
            dzSr =cmplx(0.D0,0.D0,kind=kind(0d0))
            do nCheb=1,n_r_max
               wSr  =  wSr+  w(lm,nCheb)*chebS(nCheb)
               dwSr = dwSr+ dw(lm,nCheb)*chebS(nCheb)
               ddwSr=ddwSr+ddw(lm,nCheb)*chebS(nCheb)
               zSr  =  zSr+  z(lm,nCheb)*chebS(nCheb)
               dzSr = dzSr+ dz(lm,nCheb)*chebS(nCheb)
            end do
            Vr  =  wSr* PlmS(lm,nS)
            Vt1 = dwSr*dPlmS(lm,nS)
            Vt2 =  zSr* PlmS(lm,nS)*dPhi(lm)
            Vp1 = dwSr* PlmS(lm,nS)*dPhi(lm)
            Vp2 = -zSr*dPlmS(lm,nS)
            Vor =  zSr* PlmS(lm,nS)*dLh(lm)
            Vot1= dzSr*dPlmS(lm,nS)
            Vot2= (wSr*Or_e2-ddwSr) * PlmS(lm,nS)*dPhi(lm)

            VrS(2*mc-1, nN)=VrS(2*mc-1,nN) + real(Vr)
            VrS(2*mc  , nN)=VrS(2*mc  ,nN) +aimag(Vr)
            VtS(2*mc-1, nN)=VtS(2*mc-1,nN) + real(Vt1+Vt2)
            VtS(2*mc  , nN)=VtS(2*mc  ,nN) +aimag(Vt1+Vt2)
            VpS(2*mc-1, nN)=VpS(2*mc-1,nN) + real(Vp1+Vp2)
            VpS(2*mc  , nN)=VpS(2*mc  ,nN) +aimag(Vp1+Vp2)
            VorS(2*mc-1,nN)=VorS(2*mc-1,nN)+ real(Vor)
            VorS(2*mc  ,nN)=VorS(2*mc  ,nN)+aimag(Vor)
            VotS(2*mc-1,nN)=VotS(2*mc-1,nN)+ real(Vot1+Vot2)
            VotS(2*mc  ,nN)=VotS(2*mc  ,nN)+aimag(Vot1+Vot2)
         end do

      end if ! Equatorial point ?

      !--- Extra factors, contructing z-vorticity:
      do nS=1,(nZmax+1)/2 ! North HS
         OS   =OsinTS(nS)
         sinT =1.D0/OS
         cosT =SQRT(1.D0-sinT**2)
         Or_e1=1.D0/rS(nS)
         Or_e2=Or_e1*Or_e1
         do mc=1,n_m_max
            VrS(2*mc-1,nS)=sinT*Or_e2*VrS(2*mc-1,nS)+cosT*Or_e1*OS*VtS(2*mc-1,nS)
            VrS(2*mc  ,nS)=sinT*Or_e2*VrS(2*mc  ,nS)+cosT*Or_e1*OS*VtS(2*mc  ,nS)
            VpS(2*mc-1,nS)=Or_e1*OS*VpS(2*mc-1,nS)
            VpS(2*mc  ,nS)=Or_e1*OS*VpS(2*mc  ,nS)
            VtS(2*mc-1,nS)=cosT*Or_e2*VrS(2*mc-1,nS)-sinT*Or_e1*OS*VtS(2*mc-1,nS)
            VtS(2*mc  ,nS)=cosT*Or_e2*VrS(2*mc  ,nS)-sinT*Or_e1*OS*VtS(2*mc  ,nS)
            VorS(2*mc-1,nS)=cosT*Or_e2*VorS(2*mc-1,nS)-Or_e1*VotS(2*mc-1,nS)
            VorS(2*mc  ,nS)=cosT*Or_e2*VorS(2*mc  ,nS)-Or_e1*VotS(2*mc  ,nS)
         end do
         do mc=2*n_m_max+1,nrp
            VrS(mc,nS) =0.D0
            VpS(mc,nS) =0.D0
            VtS(mc,nS) =0.D0
            VorS(mc,nS)=0.D0
         end do
      end do

      do nS=(nZmax+1)/2+1,nZmax ! South HS
         OS   =OsinTS(nZmax-nS+1)
         sinT =1.D0/OS
         cosT =-SQRT(1.D0-sinT**2)
         Or_e1=1.D0/rS(nZmax-nS+1)
         Or_e2=Or_e1*Or_e1
         do mc=1,n_m_max
            Vr=cmplx(Or_e2*VrS(2*mc-1,nS), Or_e2*VrS(2*mc,nS), kind=kind(0.d0))
            Vt=cmplx(Or_e1*OS*VtS(2*mc-1,nS), Or_e1*OS*VtS(2*mc,nS), kind=kind(0.d0))
            VrS(2*mc-1,nS) =sinT* real(Vr)+cosT* real(Vt) ! this is now Vs
            VrS(2*mc  ,nS) =sinT*aimag(Vr)+cosT*aimag(Vt) ! this is now Vs
            VpS(2*mc-1,nS) =Or_e1*OS*VpS(2*mc-1,nS)
            VpS(2*mc  ,nS) =Or_e1*OS*VpS(2*mc  ,nS)
            VtS(2*mc-1,nS) =cosT* real(Vr)-sinT* real(Vt) ! this is now Vz
            VtS(2*mc  ,nS) =cosT*aimag(Vr)-sinT*aimag(Vt) ! this is now Vz
            VorS(2*mc-1,nS)=cosT*Or_e2*VorS(2*mc-1,nS)-Or_e1*VotS(2*mc-1,nS)
            VorS(2*mc  ,nS)=cosT*Or_e2*VorS(2*mc  ,nS)-Or_e1*VotS(2*mc  ,nS)
         end do
         do mc=2*n_m_max+1,nrp
            VrS(mc,nS) =0.D0
            VpS(mc,nS) =0.D0
            VtS(mc,nS) =0.D0
            VorS(mc,nS)=0.D0
         end do
      end do

      do nS=1,nZmax
         do mc=1,nrp
            dp=cmplx(0.D0,1.D0,kind=kind(0d0))*dble((mc-1)*minc)  ! - i m
            dpVorS(2*mc-1,nS)= real(dp)*VorS(2*mc-1,nS)-aimag(dp)*VorS(2*mc,nS)
            dpVorS(2*mc  ,nS)=aimag(dp)*VorS(2*mc-1,nS)+ real(dp)*VorS(2*mc,nS)
         end do
         do mc=2*n_m_max+1,nrp
            dpVorS(mc,nS)=0.D0
         end do
      end do

      !----- Transform m 2 phi for flow field:
      call fft_to_real(VrS,nrp,nZmax)
      call fft_to_real(VtS,nrp,nZmax)
      call fft_to_real(VpS,nrp,nZmax)
      call fft_to_real(VorS,nrp,nZmax)
      call fft_to_real(dpVorS,nrp,nZmax)

   end subroutine getPVptr
!---------------------------------------------------------------------------------
end module outPV3